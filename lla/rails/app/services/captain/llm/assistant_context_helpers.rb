# frozen_string_literal: true

# Builds optional account-scoped context for the v1 assistant chat prompt.
module Captain::Llm::AssistantContextHelpers
  private

  def contact_payload
    return if assistant.config.to_h.with_indifferent_access[:feature_contact_attributes].blank?

    contact = conversation&.contact
    return if contact.blank?

    {
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: contact.identifier,
      custom_attributes: contact.custom_attributes
    }
  end

  def custom_tools_metadata
    return [] unless Captain::Assistant.custom_http_tools_enabled_for?(assistant.account)

    assistant.account.captain_custom_tools.enabled.map do |tool|
      { name: tool.slug, description: tool.description }
    end
  rescue StandardError => e
    Rails.logger.error("AssistantChatService custom tools error: #{e.class.name}")
    []
  end

  def inbox_timezone
    conversation&.inbox&.timezone.presence || 'UTC'
  end

  def response_context
    return if assistant.config.to_h.with_indifferent_access[:feature_faq].blank?

    responses = nearest_responses
    return if responses.blank?

    responses.map { |item| "Q: #{item.question}\nA: #{item.answer}" }.join("\n\n")
  end

  def nearest_responses
    scope = assistant.responses.approved
    return if scope.none?

    embedding = Captain::Llm::EmbeddingService.new(account_id: assistant.account_id).get_embedding(last_user_text.to_s)
    scope.nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(self.class::RESPONSE_CONTEXT_LIMIT).to_a
  rescue StandardError => e
    Rails.logger.error("AssistantChatService retrieval error: #{e.message}")
    nil
  end

  def last_user_text
    entry = Array(@last_messages).reverse.find { |item| item[:role].to_s == 'user' }
    text, = split_content(entry&.[](:content))
    text
  end
end
