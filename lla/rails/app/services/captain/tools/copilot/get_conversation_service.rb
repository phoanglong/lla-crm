# frozen_string_literal: true

class Captain::Tools::Copilot::GetConversationService < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  def self.name
    'get_conversation'
  end

  description 'Get details of a conversation including messages and contact information'
  param :conversation_id, type: :integer, desc: 'ID of the conversation to retrieve', required: true

  def execute(conversation_id:)
    return 'Conversation not found' unless active?

    display_id = Integer(conversation_id, exception: false)
    conversation = permissible_conversations.find_by(display_id: display_id) if display_id&.positive?
    return 'Conversation not found' if conversation.blank?

    bounded_output(conversation.to_llm_text(include_private_messages: true))
  end

  def active?
    %w[conversation_manage conversation_unassigned_manage conversation_participating_manage].any? do |permission|
      user_has_permission(permission)
    end
  end

  private

  def permissible_conversations
    Conversations::PermissionFilterService.new(assistant.account.conversations, user, assistant.account).perform
  end
end
