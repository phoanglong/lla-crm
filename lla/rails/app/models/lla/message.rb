# frozen_string_literal: true

module Lla::Message
  def self.prepended(base)
    base.class_eval do
      scope :with_call, -> { includes(call: :accepted_by_agent) }
    end
  end

  def push_event_data
    super.tap do |data|
      data[:call] = call.push_event_data if content_type == 'voice_call' && call.present?
    end
  end

  private

  # A conversation an assistant is handling sits in `pending`. When a human agent
  # replies, the conversation has to become theirs — otherwise the assistant keeps
  # answering over the agent, and the conversation never appears in the open queue
  # the agent is working from.
  #
  # `Current.user` and `Current.executed_by` are cleared around the status change so
  # the resulting activity message reads as the system opening the conversation
  # rather than as the agent doing it by hand, and restored afterwards whatever
  # happens.
  def mark_pending_conversation_as_open_for_human_response
    return unless captain_pending_conversation?
    return unless human_response?
    return if private?
    return if template_bootstrap_message?

    previous_user = Current.user
    previous_executed_by = Current.executed_by
    Current.user = nil
    Current.executed_by = nil

    begin
      conversation.open!
      create_captain_auto_open_activity_message if conversation.saved_change_to_status?
    ensure
      Current.user = previous_user
      Current.executed_by = previous_executed_by
    end
  end

  def captain_pending_conversation?
    return false unless conversation.pending?

    ::CaptainInbox.exists?(inbox_id: conversation.inbox_id)
  end

  # The outbound template that starts a WhatsApp conversation is not a human reply
  # to anything: there is nothing incoming yet for it to be a reply to.
  def template_bootstrap_message?
    additional_attributes['template_params'].present? && !conversation.messages.incoming.exists?
  end

  def create_captain_auto_open_activity_message
    ::Conversations::ActivityMessageJob.perform_later(
      conversation,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: I18n.t('conversations.activity.captain.auto_opened_after_agent_reply',
                      locale: conversation.account.locale)
    )
  end
end
