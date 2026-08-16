# frozen_string_literal: true

class Captain::Llm::FaqObservationWriter
  def initialize(account:, conversation:, language:)
    @account = account
    @conversation = conversation
    @language = language
  end

  def attach(suggestion, faq, expected_fingerprint)
    suggestion.with_lock do
      suggestion.reload
      raise Captain::Llm::ConversationFaqService::SuggestionChangedError unless suggestion.content_fingerprint == expected_fingerprint
      next discard(faq) unless suggestion.open?

      existing = suggestion.observations.find_by(conversation_id: conversation.id)
      next existing if existing

      observation = create(faq, status: :attached, suggestion: suggestion)
      suggestion.update!(source_count: suggestion.observations.attached.count)
      observation
    end
  end

  def discard(faq)
    create(faq, status: :discarded)
  end

  private

  attr_reader :account, :conversation, :language

  def create(faq, status:, suggestion: nil)
    observation = Captain::FaqObservation.new(observation_attributes(faq, status, suggestion))
    observation.validate!
    existing = find_existing(observation.source_fingerprint)
    return existing if existing

    observation.save!
    observation
  rescue ActiveRecord::RecordNotUnique
    find_existing(observation.source_fingerprint) || raise
  end

  def observation_attributes(faq, status, suggestion)
    {
      account: account,
      conversation: conversation,
      faq_suggestion: suggestion,
      generated_question: faq.fetch('question'),
      generated_answer: faq.fetch('answer'),
      language: language,
      status: status
    }
  end

  def find_existing(fingerprint)
    Captain::FaqObservation.find_by(
      account_id: account.id, conversation_id: conversation.id, source_fingerprint: fingerprint
    )
  end
end
