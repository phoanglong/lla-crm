# frozen_string_literal: true

require 'digest'

class Captain::Llm::ConversationFaqService < Lla::Llm::BackgroundService
  class SuggestionChangedError < StandardError; end

  DISTANCE_THRESHOLD = 0.3
  MATCH_LIMIT = 5
  MAX_FAQS = 3
  MAX_QUESTION_BYTES = 300
  MAX_ANSWER_BYTES = 4_000
  EMBEDDING_DIMENSIONS = 1536
  GENERATION_FEATURE = 'conversation_faq_generation'
  MATCHING_FEATURE = 'conversation_faq_matching'
  SENSITIVE_PATTERN = %r{https?://|\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b|\b(?:password|otp|passcode|credit card)\b|\b\d{10,}\b}i

  def self.language_for(conversation)
    language = conversation.language.presence || conversation.account.locale.presence || I18n.default_locale.to_s
    language.to_s.tr('-', '_').split('_').first.downcase
  end

  def initialize(assistant, conversation)
    super()
    @assistant_id = assistant&.id
    @conversation_id = conversation&.id
    @account_id = conversation&.account_id
  end

  def generate_suggestions
    return [] unless assign_runtime_context

    @content_service = Captain::Llm::ConversationFaqContentService.new(assistant, conversation)
    return [] unless @content_service.human_reply?

    generate.filter_map { |faq| route_candidate_safely(faq) }
  end

  private

  attr_reader :content_service, :embedding_service, :observation_writer

  def assign_runtime_context
    valid = assign_memory_runtime_context(
      assistant_id: @assistant_id, conversation_id: @conversation_id, account_id: @account_id
    )
    return false unless valid
    return false unless ActiveModel::Type::Boolean.new.cast(assistant.config['feature_faq'])

    @embedding_service = Captain::Llm::EmbeddingService.new(account_id: account.id)
    @observation_writer = Captain::Llm::FaqObservationWriter.new(
      account: account, conversation: conversation, language: faq_language
    )
    true
  end

  def route_candidate_safely(faq)
    route_candidate(faq)
  rescue SuggestionChangedError
    raise
  rescue StandardError => e
    capture_failure(e, 'conversation_faq_candidate')
    nil
  end

  def route_candidate(faq)
    embedding = embedding_service.get_embedding(candidate_text(faq))
    raise TypeError, 'invalid FAQ embedding' unless valid_embedding?(embedding)

    return observation_writer.discard(faq) if matching_record(approved_faqs, faq, embedding)
    return observation_writer.discard(faq) if matching_record(dismissed_suggestions, faq, embedding)

    suggestion, expected_fingerprint = matching_suggestion(faq, embedding)
    unless suggestion
      suggestion = find_or_create_suggestion(faq, embedding)
      expected_fingerprint = suggestion.content_fingerprint
    end
    return observation_writer.discard(faq) unless suggestion.open?

    observation_writer.attach(suggestion, faq, expected_fingerprint)
  end

  def matching_record(relation, faq, embedding)
    likely_matches(relation, embedding).find { |record| same_faq?(faq, record) }
  end

  def matching_suggestion(faq, embedding)
    likely_matches(open_suggestions, embedding).each do |record|
      expected_fingerprint = record.content_fingerprint
      return [record, expected_fingerprint] if same_faq?(faq, record)
    end

    [nil, nil]
  end

  def likely_matches(relation, embedding)
    return [] unless relation.where.not(embedding: nil).exists?

    relation.where.not(embedding: nil)
            .nearest_neighbors(:embedding, embedding, distance: 'cosine')
            .limit(MATCH_LIMIT)
            .select { |record| record.neighbor_distance < DISTANCE_THRESHOLD }
  end

  def same_faq?(candidate, existing_record)
    comparison = {
      candidate: candidate.slice('question', 'answer'),
      existing: { question: existing_record.question, answer: existing_record.answer }
    }
    result = request_json(
      system_prompt: Captain::Llm::ConversationFaqPromptsService.same_faq,
      content: comparison.to_json,
      span_name: 'llm.captain.faq_match',
      feature: MATCHING_FEATURE,
      metadata: { feature_name: 'conversation_faq_match', assistant_id: assistant.id, language: faq_language }
    )['same_faq']
    raise TypeError, 'same_faq must be a boolean' unless [true, false].include?(result)

    result
  end

  def find_or_create_suggestion(faq, embedding)
    fingerprint = content_fingerprint(faq)
    relation = assistant.faq_suggestions.where(account_id: account.id, language: faq_language)
    existing = relation.find_by(content_fingerprint: fingerprint)
    return existing if existing

    relation.create!(
      question: faq.fetch('question'),
      answer: faq.fetch('answer'),
      embedding: embedding,
      content_fingerprint: fingerprint
    )
  rescue ActiveRecord::RecordNotUnique
    relation.find_by!(content_fingerprint: fingerprint)
  end

  def open_suggestions
    assistant.faq_suggestions.where(account_id: account.id).open.by_language(faq_language)
  end

  def dismissed_suggestions
    assistant.faq_suggestions.where(account_id: account.id).dismissed.by_language(faq_language)
  end

  def approved_faqs
    assistant.responses.where(account_id: account.id).approved
  end

  def generate
    response = request_json(
      system_prompt: Captain::Llm::ConversationFaqPromptsService.generator(language_name(faq_language)),
      content: content_service.generate,
      span_name: 'llm.captain.conversation_faq',
      feature: GENERATION_FEATURE,
      metadata: { feature_name: 'conversation_faq', assistant_id: assistant.id, language: faq_language }
    )
    normalize_faqs(response['faqs'])
  rescue RubyLLM::Error => e
    capture_failure(e, 'conversation_faq_generation')
    []
  end

  def normalize_faqs(value)
    return [] unless value.is_a?(Array)

    value.first(MAX_FAQS).filter_map do |candidate|
      normalize_candidate(candidate) if candidate.is_a?(Hash)
    end.uniq
  end

  def normalize_candidate(candidate)
    data = candidate.stringify_keys
    question = bounded_text(data['question'], MAX_QUESTION_BYTES)
    answer = bounded_text(data['answer'], MAX_ANSWER_BYTES)
    return if question.blank? || answer.blank? || "#{question}\n#{answer}".match?(SENSITIVE_PATTERN)

    { 'question' => question, 'answer' => answer }
  end

  def bounded_text(value, max_bytes)
    return unless value.is_a?(String) && value.bytesize <= max_bytes

    value.unicode_normalize(:nfc).squish.presence
  end

  def valid_embedding?(embedding)
    embedding.is_a?(Array) && embedding.length == EMBEDDING_DIMENSIONS &&
      embedding.all? { |value| value.is_a?(Numeric) && value.finite? }
  end

  def candidate_text(faq)
    "#{faq.fetch('question')}: #{faq.fetch('answer')}"
  end

  def content_fingerprint(faq)
    normalized = [faq.fetch('question'), faq.fetch('answer')]
                 .map { |value| value.unicode_normalize(:nfc).squish.downcase }
                 .join("\n")
    Digest::SHA256.hexdigest(normalized)
  end

  def faq_language
    @faq_language ||= self.class.language_for(conversation)
  end

  def language_name(language)
    ISO_639.find(language)&.english_name&.downcase || 'english'
  end
end
