# frozen_string_literal: true

require 'digest'

# Tra cứu FAQ đã duyệt của trợ lý bằng tương đồng ngữ nghĩa (pgvector/neighbor).
class Captain::Tools::FaqLookupTool < Captain::Tools::BasePublicTool
  RESULT_LIMIT = 5

  description 'Search FAQ responses using semantic similarity to find relevant answers'
  param :query, type: 'string', desc: 'The question or topic to search for in the FAQ database'

  def perform(tool_context, query:)
    log_tool_usage('searching', query_log_metadata(query))

    responses = search_responses(query)
    if responses.empty?
      log_tool_usage('no_results', query_log_metadata(query))
      return "No relevant FAQs found for: #{query}"
    end

    log_tool_usage('found_results', query_log_metadata(query).merge(count: responses.size))
    record_retrieved_ids(tool_context.state, responses)
    format_responses(responses)
  end

  private

  def query_log_metadata(query)
    value = query.to_s
    { query_length: value.length, query_sha256: Digest::SHA256.hexdigest(value)[0, 12] }
  end

  def search_responses(query)
    embedding = Captain::Llm::EmbeddingService.new(account_id: assistant.account_id).get_embedding(query)

    assistant.responses
             .approved
             .nearest_neighbors(:embedding, embedding, distance: 'cosine')
             .limit(RESULT_LIMIT)
             .to_a
  end

  def record_retrieved_ids(state, responses)
    merge_run_metadata(state, :faq_ids, responses.map(&:id))

    document_ids = responses.filter_map { |r| r.documentable_id if r.documentable_type == 'Captain::Document' }
    merge_run_metadata(state, :document_ids, document_ids) if document_ids.any?
  end

  def format_responses(responses)
    responses.map do |response|
      lines = ["Question: #{response.question}", "Answer: #{response.answer}"]
      source = response.documentable.try(:external_link)
      lines << "Source: #{source}" if source.present? && !source.start_with?('PDF:')
      lines.join("\n")
    end.join("\n\n")
  end
end
