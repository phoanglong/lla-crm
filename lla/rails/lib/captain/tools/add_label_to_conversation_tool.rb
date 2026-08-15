# frozen_string_literal: true

# Gắn nhãn có sẵn của account vào hội thoại (không tự tạo nhãn mới).
class Captain::Tools::AddLabelToConversationTool < Captain::Tools::BasePublicTool
  description 'Add a label to a conversation'
  param :label_name, type: 'string', desc: 'The name of the label to add'

  def perform(tool_context, label_name:)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' if conversation.blank?
    return 'Label name is required' if label_name.blank?

    label = account_scoped(Label).find_by(title: label_name.strip.downcase)
    return 'Label not found' if label.blank?

    conversation.add_labels([label.title])
    log_tool_usage('added_label', { conversation_id: conversation.id, label: label.title })

    "Label '#{label.title}' added to conversation ##{conversation.display_id}"
  end
end
