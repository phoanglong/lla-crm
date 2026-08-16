# frozen_string_literal: true

module Lla::MessageTemplates::HookExecutionService
  MAX_ATTACHMENT_WAIT_SECONDS = 4

  def trigger_templates
    super
    return unless should_process_captain_response?
    return perform_handoff unless inbox.captain_active?

    schedule_captain_response
  end

  def should_send_greeting?
    return false if captain_handling_conversation?

    super
  end

  def should_send_out_of_office_message?
    return false if captain_handling_conversation?

    super
  end

  def should_send_email_collect?
    return false if captain_handling_conversation?

    super
  end

  private

  def schedule_captain_response
    token = Lla::Captain::ResponseCoordination.scheduling_token(message.id)
    key = response_schedule_key
    return unless Redis::Alfred.set(key, token, nx: true, ex: Lla::Captain::ResponseCoordination::SCHEDULE_TTL)

    enqueue_captain_response
  rescue StandardError
    Redis::Alfred.delete_if_equals(key, token) if key && token
    raise
  end

  def enqueue_captain_response
    job_args = [conversation, captain_assistant]
    return Captain::Conversation::ResponseBuilderJob.perform_later(*job_args) if message.attachments.blank?

    Captain::Conversation::ResponseBuilderJob.set(wait: calculate_attachment_wait_time).perform_later(*job_args)
  end

  def calculate_attachment_wait_time
    1.second + [message.attachments.size, MAX_ATTACHMENT_WAIT_SECONDS].min.seconds
  end

  def should_process_captain_response?
    conversation.pending? && message.incoming? && valid_captain_context?
  end

  def valid_captain_context?
    assistant = captain_assistant
    assistant.present? &&
      assistant.account_id == conversation.account_id &&
      inbox.account_id == conversation.account_id &&
      message.account_id == conversation.account_id
  end

  def perform_handoff
    handed_off = conversation.reload.with_lock do
      next false unless conversation.pending?

      create_handoff_message!
      conversation.bot_handoff!
      raise ActiveRecord::RecordInvalid, conversation unless conversation.reload.open?

      true
    end
    return unless handed_off

    Rails.logger.info("LLA Captain quota handoff account_id=#{conversation.account_id} conversation_id=#{conversation.id}")
    send_out_of_office_message_after_handoff
  end

  def create_handoff_message!
    conversation.messages.create!(
      message_type: :outgoing,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      content: 'Transferring to another agent for further assistance.'
    )
  end

  def send_out_of_office_message_after_handoff
    return if conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)
  end

  def captain_handling_conversation?
    conversation.pending? && valid_captain_context?
  end

  def captain_assistant
    inbox.respond_to?(:captain_assistant) ? inbox.captain_assistant : nil
  end

  def response_schedule_key
    Lla::Captain::ResponseCoordination.schedule_key(
      account_id: conversation.account_id,
      conversation_id: conversation.id
    )
  end
end
