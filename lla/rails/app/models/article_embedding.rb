# frozen_string_literal: true

class ArticleEmbedding < ApplicationRecord
  SUPPORTED_DIMENSIONS = [1536].freeze

  belongs_to :article
  has_neighbors :embedding, normalize: true

  scope :active, -> { where(active: true) }
  scope :for_profile, ->(model, dimensions) { where(model: model, dimensions: dimensions) }

  validates :account_id, :portal_id, :model, :dimensions, :content_digest,
            :term_digest, :index_version, presence: true
  validates :model, length: { in: 3..100 }
  validates :dimensions, inclusion: { in: SUPPORTED_DIMENSIONS }
  validates :index_version, numericality: { only_integer: true, greater_than: 0 }
  validates :content_digest, :term_digest, length: { is: 64 }, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :article_shares_tenant
  validate :embedding_matches_profile

  private

  def article_shares_tenant
    return if article.blank? || [account_id, portal_id] == [article.account_id, article.portal_id]

    errors.add(:article, 'must belong to the embedding tenant and portal')
  end

  def embedding_matches_profile
    raw_embedding = embedding_before_type_cast
    return if raw_embedding.blank?

    size = raw_embedding.respond_to?(:size) ? raw_embedding.size : Array(raw_embedding).size
    errors.add(:embedding, 'dimension does not match the registered profile') unless size == dimensions
  rescue Neighbor::Error
    errors.add(:embedding, 'dimension does not match the registered profile')
  end
end
