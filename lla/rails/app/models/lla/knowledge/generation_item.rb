# frozen_string_literal: true

class Lla::Knowledge::GenerationItem < ApplicationRecord
  self.table_name = 'lla_knowledge_generation_items'

  STATES = %w[pending claimed succeeded failed cancelled].freeze

  belongs_to :operation, class_name: 'Lla::Knowledge::GenerationOperation',
                         foreign_key: :generation_operation_id, inverse_of: :items
  belongs_to :account, class_name: '::Account'
  belongs_to :portal, class_name: '::Portal'
  belongs_to :category, class_name: '::Category', optional: true
  belongs_to :article, class_name: '::Article', optional: true

  validates :state, inclusion: { in: STATES }
  validates :item_key_digest, :source_digest, presence: true, length: { is: 64 }
  validates :claim_digest, length: { is: 64 }, allow_nil: true
  validates :ordinal, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :attempts, numericality: { only_integer: true, in: 0..5 }
  validate :operation_shares_tenant
  validate :portal_shares_account
  validate :category_shares_tenant
  validate :article_shares_tenant

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

  def tenant_identity
    [account_id, portal_id]
  end
end
