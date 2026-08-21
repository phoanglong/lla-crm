# frozen_string_literal: true

class Captain::Tools::SearchDocumentationService < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  def self.name
    'search_documentation'
  end

  description 'Search and retrieve documentation from knowledge base'
  param :query, desc: 'Search Query', required: true

  def execute(query:)
    safe_query = bounded_query(query)
    return 'Please provide a more specific documentation query' unless meaningful_query?(safe_query)

    translated_query = Captain::Llm::TranslateQueryService
                       .new(account: assistant.account)
                       .translate(safe_query, target_language: assistant.account.locale_english_name)
    responses = Captain::AssistantResponse.search(
      translated_query,
      account_id: assistant.account_id,
      assistant_id: assistant.id
    )
    return 'No FAQs found for the given query' if responses.empty?

    bounded_output(responses.first(MAX_RESULT_COUNT).map { |response| format_response(response) }.join("\n---\n"))
  end

  private

  def format_response(response)
    result = "Question: #{response.question}\nAnswer: #{response.answer}"
    source = response.documentable&.try(:external_link)
    result += "\nSource: #{source}" if source.present?
    result
  end
end
