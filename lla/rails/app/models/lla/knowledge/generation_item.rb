# frozen_string_literal: true

class Lla::Knowledge::GenerationItem < ApplicationRecord
  self.table_name = 'lla_knowledge_generation_items'

  STATES = %w[pending claimed succeeded failed cancelled].freeze
  TYPES = %w[article_generation translation reindex].freeze

  belongs_to :operation, class_name: 'Lla::Knowledge::GenerationOperation',
                         foreign_key: :generation_operation_id, inverse_of: :items
  belongs_to :account, class_name: '::Account'
  belongs_to :portal, class_name: '::Portal'
  belongs_to :category, class_name: '::Category', optional: true
  belongs_to :article, class_name: '::Article', optional: true
  belongs_to :output_article, class_name: '::Article', optional: true

  validates :state, inclusion: { in: STATES }
  validates :item_type, inclusion: { in: TYPES }
  validates :item_key_digest, :source_digest, presence: true, length: { is: 64 }
  validates :claim_digest, length: { is: 64 }, allow_nil: true
  validates :ordinal, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :attempts, numericality: { only_integer: true, in: 0..5 }
  validate :operation_shares_tenant
  validate :portal_shares_account
  validate :category_shares_tenant
  validate :article_shares_tenant
  validate :output_article_shares_tenant
  validate :result_matches_type

  private

  def operation_shares_tenant
    return if operation.blank? || tenant_identity == [operation.account_id, operation.portal_id]

    errors.add(:operation, 'must share the item tenant and portal')
  end

  def portal_shares_account
    errors.add(:portal, 'must belong to the item account') if portal && portal.account_id != account_id
  end

  def category_shares_tenant
    return if category.blank? || tenant_identity == [category.account_id, category.portal_id]

    errors.add(:category, 'must belong to the item tenant and portal')
  end

  def article_shares_tenant
    return if article.blank? || tenant_identity == [article.account_id, article.portal_id]

    errors.add(:article, 'must belong to the item tenant and portal')
  end

  def output_article_shares_tenant
    return if output_article.blank? || tenant_identity == [output_article.account_id, output_article.portal_id]

    errors.add(:output_article, 'must belong to the item tenant and portal')
  end

  def result_matches_type
    return if result_state_valid?

    errors.add(:base, 'item result does not match its type and state')
  end

  def result_state_valid?
    return article_id.blank? && output_article_id.blank? unless state == 'succeeded'

    expected_result_presence == [article_id.present?, output_article_id.present?]
  end

  def expected_result_presence
    {
      'article_generation' => [true, false],
      'translation' => [false, true],
      'reindex' => [false, false]
    }.fetch(item_type, [false, false])
  end

  def tenant_identity
    [account_id, portal_id]
  end
end
