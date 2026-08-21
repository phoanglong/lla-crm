# frozen_string_literal: true

class Captain::Tools::SearchReplyDocumentationService < RubyLLM::Tool
  prepend Captain::Tools::Instrumentation
  include Captain::Tools::PermissionHelpers

  description 'Search and retrieve documentation/FAQs from knowledge base'
  param :query, desc: 'Search Query', required: true

  def initialize(account:, assistant: nil)
    @account = account
    @assistant = assistant
    super()
  end

  def name
    'search_documentation'
  end

  def execute(query:)
    safe_query = bounded_query(query)
    return 'Please provide a more specific documentation query' unless meaningful_query?(safe_query)

    translated_query = Captain::Llm::TranslateQueryService
                       .new(account: @account)
                       .translate(safe_query, target_language: @account.locale_english_name)
    responses = search_responses(translated_query)
    return 'No FAQs found for the given query' if responses.empty?

    bounded_output(responses.first(MAX_RESULT_COUNT).map { |response| format_response(response) }.join("\n---\n"))
  end

  private

  def search_responses(query)
    responses = @account.captain_assistant_responses.approved
    return responses.none if @assistant.present? && @assistant.account_id != @account.id

    embedding = Captain::Llm::EmbeddingService.new(account_id: @account.id).get_embedding(query)
    responses = responses.where(assistant_id: @assistant.id) if @assistant.present?

    responses.nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(5)
  end

  def format_response(response)
    result = "Question: #{response.question}\nAnswer: #{response.answer}"
    source = response.documentable&.try(:external_link)
    result += "\nSource: #{source}" if source.present?
    result
  end
end
