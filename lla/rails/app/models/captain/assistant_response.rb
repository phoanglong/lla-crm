# frozen_string_literal: true

# Một cặp hỏi-đáp (FAQ) của trợ lý, kèm vector nhúng để tra cứu ngữ nghĩa
# (pgvector qua gem neighbor).
class Captain::AssistantResponse < ApplicationRecord
  self.table_name = 'captain_assistant_responses'

  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :account
  belongs_to :documentable, polymorphic: true, optional: true

  has_neighbors :embedding

  enum status: { pending: 0, approved: 1 }

  scope :ordered, -> { order(created_at: :desc) }
  scope :by_assistant, ->(assistant_id) { where(assistant_id: assistant_id) }

  before_validation :assign_account_from_assistant
  validate :document_belongs_to_account

  # FAQ tạo hoặc đổi nội dung phải tính lại vector; không giữ embedding cũ của
  # một câu hỏi/câu trả lời đã bị chỉnh sửa.
  before_save :clear_stale_embedding, if: :faq_content_changed?
  after_commit :enqueue_embedding_update, if: :embedding_update_due?

  # Không cung cấp biến thể unscoped: mọi tìm kiếm phải nêu rõ tenant và
  # assistant để không thể vô tình đọc vector của tài khoản khác.
  def self.search(query, account_id:, assistant_id:)
    embedding = Captain::Llm::EmbeddingService.new(account_id: account_id).get_embedding(query)
    where(account_id: account_id, assistant_id: assistant_id)
      .approved
      .nearest_neighbors(:embedding, embedding, distance: 'cosine')
      .limit(5)
  end

  validates :question, presence: true
  validates :answer, presence: true

  scope :with_document, -> { where.not(documentable_id: nil) }

  private

  # Account luôn theo assistant — chặn lệch account giữa FAQ và trợ lý.
  def assign_account_from_assistant
    self.account = assistant.account if assistant.present?
  end

  def document_belongs_to_account
    return unless documentable.is_a?(Captain::Document) && assistant.present?
    return if documentable.account_id == assistant.account_id

    errors.add(:documentable, 'must belong to the same account as the assistant')
  end

  def embedding_update_due?
    return embedding.blank? if saved_change_to_id?

    saved_change_to_question? || saved_change_to_answer?
  end

  def faq_content_changed?
    will_save_change_to_question? || will_save_change_to_answer?
  end

  def clear_stale_embedding
    self.embedding = nil if persisted?
  end

  def enqueue_embedding_update
    Captain::Llm::ResponseEmbeddingJob.perform_later(self)
  end
end
