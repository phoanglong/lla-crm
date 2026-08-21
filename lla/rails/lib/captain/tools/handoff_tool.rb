# frozen_string_literal: true

# Chuyển hội thoại cho người thật: ghi chú riêng lý do (nếu có), phát sự kiện
# bot_handoff của CE và gửi thông điệp ngoài giờ làm việc nếu áp dụng.
class Captain::Tools::HandoffTool < Captain::Tools::BasePublicTool
  description 'Hand off the conversation to a human agent when unable to assist further'
  param :reason, type: 'string', desc: 'The reason why handoff is needed (optional)', required: false

  def perform(tool_context, reason: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' if conversation.blank?

    log_tool_usage('tool_handoff', { conversation_id: conversation.id, reason_present: reason.present? })

    note = create_handoff_note(conversation, reason)
    set_run_metadata(tool_context.state, :handoff_note_id, note.id) if reason.present?

    conversation.bot_handoff!
    MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)

    reason.present? ? "Conversation handed off to human support team (Reason: #{reason})" : 'Conversation handed off to human support team'
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    'Failed to handoff conversation'
  end

  private

  def create_handoff_note(conversation, reason)
    conversation.messages.create!(
      account: conversation.account,
      inbox: conversation.inbox,
      message_type: :outgoing,
      private: true,
      content: reason,
      sender: assistant
    )
  end
end
