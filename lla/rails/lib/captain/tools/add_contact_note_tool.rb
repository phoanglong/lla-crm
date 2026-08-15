# frozen_string_literal: true

# Ghi chú vào hồ sơ contact. Note của CE cần một User làm tác giả — dùng user
# đầu tiên của account thay mặt trợ lý.
class Captain::Tools::AddContactNoteTool < Captain::Tools::BasePublicTool
  description 'Add a note to a contact profile'
  param :note, type: 'string', desc: 'The note content to add to the contact'

  def perform(tool_context, note:)
    contact = find_contact(tool_context.state)
    return 'Contact not found' if contact.blank?
    return 'Note content is required' if note.blank?

    log_tool_usage('add_contact_note', { contact_id: contact.id, note_length: note.length })

    contact.notes.create!(
      account: assistant.account,
      content: note,
      user: assistant.account.users.first
    )

    "Note added successfully to contact #{contact.name} (ID: #{contact.id})"
  end
end
