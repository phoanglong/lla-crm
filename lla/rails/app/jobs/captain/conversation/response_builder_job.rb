# frozen_string_literal: true

class Captain::Conversation::ResponseBuilderJob < ApplicationJob
  include Captain::Conversation::V1ActionClassifier
  include Captain::Conversation::V1FalsePromiseHandler
  include Captain::Conversation::MessageBuilder
  include Captain::Conversation::ResponseCoordination
  include Captain::Conversation::V2Runtime
  include Captain::Conversation::QuotaAccounting

  MAX_MESSAGE_LENGTH = 10_000
  retry_on ActiveStorage::FileNotFoundError, attempts: 3, wait: 2.seconds do |job, _error|
    job.send(:release_quota_after_retry_exhaustion)
  end
  retry_on Faraday::BadRequestError, attempts: 3, wait: 2.seconds do |job, _error|
    job.send(:release_quota_after_retry_exhaustion)
  end

  def perform(conversation, assistant)
    assign_context(conversation, assistant)
    return unless response_execution_ready?

    Current.executed_by = @assistant
    generate_current_response
  rescue ActiveStorage::FileNotFoundError, Faraday::BadRequestError => e
    @keep_quota_reservation = true
    handle_error(e)
    raise e
  rescue StandardError => e
    handle_error(e)
  ensure
    Current.executed_by = nil
    release_response_quota unless @quota_settled || @keep_quota_reservation
    release_coordination
    reschedule_latest_response if @reschedule_required
  end

  private

  delegate :account, :inbox, to: :@conversation

  def response_execution_ready?
    return false unless prepare_response_job
    return true if reserve_response_quota

    handle_quota_denial
    false
  end

  def generate_current_response
    captain_v2_enabled? ? generate_response_with_v2 : generate_and_process_response
  end

  def assign_context(conversation, assistant)
    @conversation = conversation
    @inbox = conversation.inbox
    @assistant = assistant
    @schedule_key = coordination_key(:schedule)
    @execution_key = coordination_key(:execution)
  end

  def prepare_response_job
    return false unless valid_runtime_context? && valid_scheduling_token? && acquire_execution_lock

    @starting_message_id = latest_incoming_message_id
    @starting_message_id.present? && conversation_pending? && !already_responded_to_trigger?
  end

  def generate_and_process_response
    message_history = collect_previous_messages
    @response = Captain::Llm::AssistantChatService.new(assistant: @assistant, conversation: @conversation).generate_response(
      message_history: message_history
    )
    validate_response!
    return mark_for_reschedule unless response_still_current?

    classify_v1_response_action(message_history) if response_still_current?
    repair_v1_false_promise_response(message_history) if response_still_current?
    process_response
  end

  def validate_response!
    raise ArgumentError, 'Captain response must be a hash' unless @response.is_a?(Hash)
    raise ArgumentError, 'Captain response is blank' if @response['response'].blank? && !@response['handoff_tool_called']
  end

  def process_response
    if v2_handoff_tool_fired?
      process_v2_handoff_result
    elsif v1_handoff_requested?
      process_v1_handoff if response_still_current?
    elsif response_still_current?
      deliver_standard_response
    end
  end

  def deliver_standard_response
    result = @conversation.reload.with_lock do
      next :stale unless delivery_allowed?

      message = create_messages
      raise ActiveRecord::RecordInvalid, @conversation unless consume_response_quota

      message
    end

    if result == :stale
      mark_for_reschedule if conversation_pending? && latest_incoming_message_id != @starting_message_id
    else
      capture_assistant_session(result_message: result, credits_consumed: 1.0)
    end
  end

  def delivery_allowed?
    conversation_pending? &&
      latest_incoming_message_id == @starting_message_id &&
      !human_replied_after_trigger? &&
      !already_responded_to_trigger?
  end

  def v1_handoff_requested?
    legacy_v1_handoff_token? || classifier_v1_handoff_requested?
  end

  def classifier_v1_handoff_requested?
    @response['action'] == 'handoff'
  end

  def legacy_v1_handoff_token?
    @response['response'] == 'conversation_handoff'
  end

  def v2_handoff_tool_fired?
    ActiveModel::Type::Boolean.new.cast(@response['handoff_tool_called'])
  end

  def process_v1_handoff
    handed_off = false
    I18n.with_locale(@assistant.account.locale) do
      handed_off = @conversation.reload.with_lock do
        next false unless delivery_allowed?

        log_handoff
        create_handoff_message(preserve_waiting_since: true)
        @conversation.update!(waiting_since: Time.current)
        @conversation.bot_handoff!
        raise ActiveRecord::RecordInvalid, @conversation unless @conversation.reload.open?

        true
      end
    end
    return unless handed_off

    send_out_of_office_message_if_applicable
  end

  def log_handoff
    Rails.logger.info(
      "LLA Captain V1 handoff account_id=#{account.id} conversation_id=#{@conversation.id} " \
      "source=#{@response&.dig('action_source') || 'legacy'} reason=#{@response&.dig('action_reason')}"
    )
  end

  def send_out_of_office_message_if_applicable
    return if @conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(@conversation)
  end

  def create_handoff_message(preserve_waiting_since: false)
    @handoff_message = create_outgoing_message(
      @assistant.config['handoff_message'].presence || I18n.t('conversations.captain.handoff'),
      preserve_waiting_since: preserve_waiting_since
    )
  end

  def handle_error(error)
    return unless error_context_valid?

    ChatwootExceptionTracker.new(error, account: account).capture_exception
    annotate_error_response(error)
    process_v1_handoff if response_still_current? && !human_replied_after_trigger?
    true
  end

  def error_context_valid?
    @conversation.present? && @assistant.present? && valid_runtime_context?
  end

  def annotate_error_response(error)
    @response ||= {}
    @response['action_source'] ||= 'error'
    @response['action_reason'] ||= error.class.name.underscore.tr('/', '_')
  end

  def conversation_pending?
    status = Conversation.uncached { Conversation.where(id: @conversation.id).pick(:status) }
    status == 'pending' || status == Conversation.statuses[:pending]
  end
end
