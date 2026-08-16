# frozen_string_literal: true

# Atomically promotes one open suggestion into an approved FAQ. The row lock is
# the idempotency fence for concurrent approve/dismiss requests.
class Captain::FaqSuggestionApprovalService
  def initialize(suggestion, attributes = {})
    @suggestion = suggestion
    @attributes = attributes
  end

  def perform
    suggestion.with_lock do
      raise ActiveRecord::RecordNotFound unless suggestion.open?

      suggestion.update!(attributes) if attributes.present?
      response = suggestion.assistant.responses.create!(
        account: suggestion.account,
        question: suggestion.question,
        answer: suggestion.answer,
        status: :approved
      )
      suggestion.approved!
      response
    end
  end

  private

  attr_reader :suggestion, :attributes
end
