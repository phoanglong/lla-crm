# frozen_string_literal: true

class Captain::InboxPendingConversationsResolutionJob < ApplicationJob
  CAPTAIN_INFERENCE_RESOLVE_ACTIVITY_REASON = 'no outstanding questions'
  CAPTAIN_INFERENCE_HANDOFF_ACTIVITY_REASON = 'pending clarification from customer'
  DEFAULT_INACTIVITY_MINUTES = 60
  MIN_INACTIVITY_MINUTES = 10
  MAX_INACTIVITY_MINUTES = 10_080
  MAX_REASON_BYTES = 500
  EFFECT_ATTRIBUTE = 'lla_captain_resolution'

  queue_as :low

  def perform(inbox)
    assign_runtime_context(inbox)
    return unless valid_runtime_context?

    Current.executed_by = @assistant
    @cutoff = Time.current - inactivity_minutes.minutes
    evaluate_conversation_completion? ? perform_with_evaluation : perform_time_based
  ensure
    Current.reset
  end

  private

  def assign_runtime_context(inbox)
    @inbox = Inbox.includes(:account, :captain_assistant).find_by(id: inbox.id)
    @assistant = @inbox&.captain_assistant
  end

  def valid_runtime_context?
    return false if @inbox.blank? || @assistant.blank? || @inbox.email?
    return false unless @inbox.account&.active?
    return false if @inbox.account.captain_auto_resolve_disabled?

    @assistant.account_id == @inbox.account_id
  end

  def evaluate_conversation_completion?
    @inbox.account.feature_enabled?('captain_tasks') && @inbox.account.captain_auto_resolve_evaluated?
  end

  def perform_time_based
    resolvable_pending_conversations.each do |conversation|
      apply_time_based_resolution(conversation, conversation.last_activity_at)
    rescue StandardError => e
      capture_conversation_error(e, conversation)
    end
  end

  def perform_with_evaluation
    resolvable_pending_conversations.each do |conversation|
      expected_activity = conversation.last_activity_at
      evaluation = evaluate_conversation(conversation)
      apply_evaluated_result(conversation, expected_activity, evaluation)
    rescue StandardError => e
      capture_conversation_error(e, conversation)
    end
  end

  def evaluate_conversation(conversation)
    Captain::ConversationCompletionService.new(
      account: @inbox.account,
      conversation_display_id: conversation.display_id
    ).perform
  rescue StandardError => e
    capture_conversation_error(e, conversation)
    { complete: false, reason: 'Evaluation unavailable' }
  end

  def resolvable_pending_conversations
    @inbox.conversations.pending
          .where('last_activity_at < ?', @cutoff)
          .limit(Limits::BULK_ACTIONS_LIMIT)
  end

  def apply_time_based_resolution(conversation, expected_activity)
    conversation.reload
    conversation.with_lock do
      conversation.reload
      next unless still_resolvable?(conversation, expected_activity)

      create_resolution_message(conversation, outcome: 'legacy', revision: expected_activity)
      conversation.resolved!
    end
  end

  def apply_evaluated_result(conversation, expected_activity, evaluation)
    handed_off = false
    conversation.with_captain_activity_context(**activity_context_for(evaluation)) do
      conversation.reload
      conversation.with_lock do
        conversation.reload
        next unless still_resolvable?(conversation, expected_activity)

        if evaluation[:complete] == true
          resolve_conversation(conversation, safe_reason(evaluation[:reason]), expected_activity)
        else
          handoff_conversation(conversation, safe_reason(evaluation[:reason]), expected_activity)
          handed_off = true
        end
      end
    end
    send_out_of_office_message_if_applicable(conversation.reload) if handed_off
  end

  def activity_context_for(evaluation)
    reason = if evaluation[:complete] == true
               CAPTAIN_INFERENCE_RESOLVE_ACTIVITY_REASON
             else
               CAPTAIN_INFERENCE_HANDOFF_ACTIVITY_REASON
             end

    { reason: reason, reason_type: :inference }
  end

  def still_resolvable?(conversation, expected_activity)
    conversation.pending? &&
      conversation.inbox_id == @inbox.id &&
      conversation.account_id == @inbox.account_id &&
      same_activity_revision?(conversation.last_activity_at, expected_activity) &&
      conversation.last_activity_at < @cutoff
  end

  def same_activity_revision?(current, expected)
    return current == expected if current.nil? || expected.nil?

    (current.to_f - expected.to_f).abs < 0.000001
  end

  def inactivity_minutes
    configured = Integer(@inbox.account.auto_resolve_after, exception: false) || DEFAULT_INACTIVITY_MINUTES
    configured.clamp(MIN_INACTIVITY_MINUTES, MAX_INACTIVITY_MINUTES)
  end

  def resolve_conversation(conversation, reason, revision)
    conversation.resolved!
    create_private_note(conversation, "Auto-resolved: #{reason}", outcome: 'resolved', revision: revision)
    create_resolution_message(conversation, outcome: 'resolved', revision: revision)
    conversation.dispatch_captain_inference_resolved_event
  end

  def handoff_conversation(conversation, reason, revision)
    conversation.bot_handoff!
    create_private_note(conversation, "Auto-handoff: #{reason}", outcome: 'handoff', revision: revision)
    create_handoff_message(conversation, revision: revision)
    conversation.dispatch_captain_inference_handoff_event
  end

  def send_out_of_office_message_if_applicable(conversation)
    return if conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)
  end

  def create_private_note(conversation, content, outcome:, revision:)
    conversation.messages.create!(message_attributes(conversation, content, outcome, revision).merge(private: true))
  end

  def create_resolution_message(conversation, outcome:, revision:)
    I18n.with_locale(@inbox.account.locale) do
      content = @assistant.config['resolution_message'].presence || I18n.t('conversations.activity.auto_resolution_message')
      conversation.messages.create!(message_attributes(conversation, content, outcome, revision))
    end
  end

  def create_handoff_message(conversation, revision:)
    content = @assistant.config['handoff_message']
    return if content.blank?

    conversation.messages.create!(
      message_attributes(conversation, content, 'handoff', revision).merge(preserve_waiting_since: true)
    )
  end

  def message_attributes(conversation, content, outcome, revision)
    {
      message_type: :outgoing,
      sender: @assistant,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      content: content,
      additional_attributes: {
        EFFECT_ATTRIBUTE => {
          'outcome' => outcome,
          'revision' => revision&.to_f
        }
      }
    }
  end

  def safe_reason(reason)
    reason.to_s.scrub.squish.byteslice(0, MAX_REASON_BYTES)&.scrub.presence || 'No reason provided'
  end

  def capture_conversation_error(error, conversation)
    ChatwootExceptionTracker.new(error, account: @inbox&.account).capture_exception
    Rails.logger.warn(
      "LLA Captain auto-resolution failed account_id=#{@inbox&.account_id} " \
      "inbox_id=#{@inbox&.id} conversation_id=#{conversation&.id} error=#{error.class.name}"
    )
  end
end
