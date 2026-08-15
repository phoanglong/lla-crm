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

  # FAQ tạo qua pipeline (ResponseBuilderJob…) chưa có vector — tính async.
  after_commit :enqueue_embedding_update, if: :embedding_update_due?

  # Tìm câu trả lời gần nghĩa nhất với câu hỏi (semantic search) — dùng cho
  # copilot/tra cứu tài liệu. Gọi được trên relation đã scope theo assistant.
  def self.search(query)
    embedding = Captain::Llm::EmbeddingService.new(account_id: nil).get_embedding(query)
    approved.nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(5)
  end

  validates :question, presence: true
  validates :answer, presence: true

  scope :with_document, -> { where.not(documentable_id: nil) }

  private

  # Account luôn theo assistant — chặn lệch account giữa FAQ và trợ lý.
  def assign_account_from_assistant
    self.account = assistant.account if assistant.present?
  end

  def embedding_update_due?
    embedding.blank? && (saved_change_to_id? || saved_change_to_question? || saved_change_to_answer?)
  end

  def enqueue_embedding_update
    Captain::Llm::ResponseEmbeddingJob.perform_later(self)
  end
end
