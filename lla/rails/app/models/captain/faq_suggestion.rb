# frozen_string_literal: true

# FAQ do AI đề xuất từ hội thoại thật — chờ người duyệt (approve thành
# AssistantResponse) hoặc bỏ qua. Mỗi lần gặp lại cùng câu hỏi, một observation
# được gắn thêm và source_count tăng.
class Captain::FaqSuggestion < ApplicationRecord
  self.table_name = 'captain_faq_suggestions'

  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :account

  has_many :observations, class_name: 'Captain::FaqObservation',
                          dependent: :destroy, inverse_of: :faq_suggestion

  has_neighbors :embedding

  enum status: { open: 0, approved: 1, dismissed: 2 }

  validates :question, presence: true
  validates :answer, presence: true

  scope :ordered, -> { order(created_at: :desc) }
  scope :by_language, ->(language) { where(language: language) }

  before_validation :assign_account_from_assistant

  private

  # Account luôn theo assistant — tạo qua assistant.faq_suggestions không cần
  # truyền account.
  def assign_account_from_assistant
    self.account = assistant.account if assistant.present?
  end
end
