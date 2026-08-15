# frozen_string_literal: true

# Đóng hội thoại khi trợ lý xác định vấn đề đã xử lý xong, kèm lý do vào thông
# điệp hoạt động. Tôn trọng cấu hình tắt auto-resolve của account.
class Captain::Tools::ResolveConversationTool < Captain::Tools::BasePublicTool
  description 'Resolve the conversation when the issue is handled'
  param :reason, type: 'string', desc: 'The reason why the conversation can be resolved', required: false

  def perform(tool_context, reason: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' if conversation.blank?
    return 'Auto-resolve is disabled for this account' if conversation.account.captain_auto_resolve_disabled?
    return "Conversation ##{conversation.display_id} is already resolved" if conversation.resolved?

    log_tool_usage('resolve_conversation', { conversation_id: conversation.id, reason: reason })
    conversation.with_captain_activity_context(reason: reason, reason_type: :tool) do
      conversation.resolved!
    end

    "Conversation ##{conversation.display_id} resolved"
  end
end
