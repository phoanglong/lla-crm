# frozen_string_literal: true

require 'digest'

# Một lần AI quan sát thấy câu hỏi/đáp trong hội thoại thật. Khi trùng một FAQ
# đề xuất sẵn có, observation được gắn vào suggestion đó làm bằng chứng nguồn.
class Captain::FaqObservation < ApplicationRecord
  self.table_name = 'captain_faq_observations'

  belongs_to :account
  # ::Conversation tường minh — trong namespace Captain:: còn module
  # Captain::Conversation (jobs EE) gây nhầm hằng.
  belongs_to :conversation, class_name: '::Conversation'
  belongs_to :faq_suggestion, class_name: 'Captain::FaqSuggestion', optional: true, inverse_of: :observations

  enum status: { attached: 0, discarded: 1 }

  validates :generated_question, presence: true
  validates :generated_answer, presence: true

  before_validation :assign_account, :assign_source_fingerprint
  validate :conversation_and_suggestion_share_account

  private

  def assign_account
    self.account = faq_suggestion&.account || conversation&.account
  end

  def assign_source_fingerprint
    return if conversation.blank? || generated_question.blank? || generated_answer.blank?

    normalized = [status, language, generated_question, generated_answer]
                 .map { |value| value.to_s.unicode_normalize(:nfc).squish.downcase }
                 .join("\n")
    self.source_fingerprint = Digest::SHA256.hexdigest(normalized)
  end

  def conversation_and_suggestion_share_account
    return if faq_suggestion.blank? || conversation.blank?
    return if faq_suggestion.account_id == conversation.account_id

    errors.add(:conversation, 'must belong to the same account as the FAQ suggestion')
  end
end
