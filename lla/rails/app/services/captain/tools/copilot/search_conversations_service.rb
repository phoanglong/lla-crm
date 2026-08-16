# frozen_string_literal: true

class Captain::Tools::Copilot::SearchConversationsService < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  def self.name
    'search_conversation'
  end

  description 'Search conversations based on parameters'
  param :status, type: :string, desc: 'Status: open, resolved, pending or snoozed'
  param :contact_id, type: :number, desc: 'Contact id'
  param :priority, type: :string, desc: 'Priority: low, medium, high or urgent'
  param :labels, type: :string, desc: 'Labels available'

  def execute(status: nil, contact_id: nil, priority: nil, labels: nil)
    return 'No conversations found' unless active?

    validation_error = filter_validation_error(status, contact_id, priority, labels)
    return validation_error if validation_error

    results = filtered_conversations(status, contact_id, priority, labels).limit(MAX_RESULT_COUNT).to_a
    return 'No conversations found' if results.empty?

    content = results.map do |conversation|
      conversation.to_llm_text(include_contact_details: true, include_private_messages: true)
    end
    bounded_output("Total number of conversations: #{results.length}\n#{content.join("\n---\n")}")
  end

  def active?
    %w[conversation_manage conversation_unassigned_manage conversation_participating_manage].any? do |permission|
      user_has_permission(permission)
    end
  end

  private

  def filter_validation_error(status, contact_id, priority, labels)
    return 'Please provide a conversation search filter' unless filter_present?(status, contact_id, priority, labels)
    return 'Invalid conversation status' if status.present? && !valid_status?(status)
    return 'Invalid conversation priority' if priority.present? && !valid_priority?(priority)
  end

  def filter_present?(status, contact_id, priority, labels)
    status.present? || Integer(contact_id, exception: false)&.positive? || priority.present? || meaningful_query?(labels)
  end

  def filtered_conversations(status, contact_id, priority, labels)
    conversations = permissible_conversations
    parsed_contact_id = Integer(contact_id, exception: false)
    conversations = conversations.where(contact_id: parsed_contact_id) if parsed_contact_id&.positive?
    conversations = conversations.where(status: status) if status.present?
    conversations = conversations.where(priority: priority) if priority.present?
    conversations = conversations.tagged_with(bounded_query(labels), any: true) if meaningful_query?(labels)
    conversations.order(updated_at: :desc, id: :desc)
  end

  def valid_status?(status)
    Conversation.statuses.key?(status.to_s)
  end

  def valid_priority?(priority)
    Conversation.priorities.key?(priority.to_s)
  end

  def permissible_conversations
    Conversations::PermissionFilterService.new(assistant.account.conversations, user, assistant.account).perform
  end
end
