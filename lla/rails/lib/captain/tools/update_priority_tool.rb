# frozen_string_literal: true

# Đổi độ ưu tiên hội thoại; 'nil'/chuỗi rỗng nghĩa là gỡ ưu tiên.
class Captain::Tools::UpdatePriorityTool < Captain::Tools::BasePublicTool
  VALID_PRIORITIES = %w[low medium high urgent].freeze

  description 'Update the priority of a conversation'
  param :priority, type: 'string', desc: 'The priority level: low, medium, high, urgent, or nil to remove priority'

  def perform(tool_context, priority:)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' if conversation.blank?

    normalized = priority.to_s.strip
    remove = normalized.blank? || normalized == 'nil'
    return 'Invalid priority. Valid options: low, medium, high, urgent, nil' unless remove || VALID_PRIORITIES.include?(normalized)

    new_priority = remove ? nil : normalized
    log_tool_usage('update_priority', { conversation_id: conversation.id, priority: new_priority })
    conversation.toggle_priority(new_priority)

    "Priority updated to '#{new_priority || 'none'}' for conversation ##{conversation.display_id}"
  end
end
