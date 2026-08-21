# frozen_string_literal: true

module Lla::ActionCableListener
  include Events::Types

  def copilot_message_created(event)
    event_message = event.data[:copilot_message]
    copilot_message = CopilotMessage.includes(copilot_thread: %i[account user assistant]).find_by(id: event_message&.id)
    return if copilot_message.blank? || !valid_copilot_broadcast?(copilot_message)

    thread = copilot_message.copilot_thread
    broadcast(
      thread.account,
      [thread.user.pubsub_token],
      COPILOT_MESSAGE_CREATED,
      copilot_message.push_event_data
    )
  rescue StandardError => e
    Rails.logger.error("LLA Copilot broadcast rejected message_id=#{event_message&.id} error=#{e.class.name}")
  end

  private

  def valid_copilot_broadcast?(message)
    thread = message.copilot_thread
    message.account_id == thread.account_id && thread.assistant.account_id == thread.account_id &&
      AccountUser.exists?(account_id: thread.account_id, user_id: thread.user_id)
  end
end
