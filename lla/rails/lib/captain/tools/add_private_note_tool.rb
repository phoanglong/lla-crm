# frozen_string_literal: true

# Ghi chú riêng (private note) vào hội thoại — dùng khi trợ lý cần lưu thông
# tin cho agent mà không gửi tới khách.
class Captain::Tools::AddPrivateNoteTool < Captain::Tools::BasePublicTool
  description 'Add a private note to a conversation'
  param :note, type: 'string', desc: 'The private note content'

  def perform(tool_context, note:)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' if conversation.blank?
    return 'Note content is required' if note.blank?

    log_tool_usage('add_private_note', { conversation_id: conversation.id, note_length: note.length })

    conversation.messages.create!(
      account: conversation.account,
      inbox: conversation.inbox,
      message_type: :outgoing,
      private: true,
      content: note,
      sender: assistant
    )

    'Private note added successfully'
  end
end
