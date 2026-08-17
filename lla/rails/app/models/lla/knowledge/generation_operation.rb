# frozen_string_literal: true

class Lla::Knowledge::GenerationOperation < ApplicationRecord
  self.table_name = 'lla_knowledge_generation_operations'

  RETENTION_PERIOD = 30.days
  TYPES = %w[onboarding translation reindex].freeze
  STATES = %w[
    pending planning dispatching running completed completed_with_errors skipped failed cancelled
  ].freeze
  TERMINAL_STATES = %w[completed completed_with_errors skipped failed cancelled].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :portal, class_name: '::Portal'
  belongs_to :user, class_name: '::User'
  has_many :items, class_name: 'Lla::Knowledge::GenerationItem', dependent: :delete_all, inverse_of: :operation
  has_many :outboxes, class_name: 'Lla::Knowledge::GenerationOutbox', dependent: :delete_all, inverse_of: :operation

  validates :operation_type, inclusion: { in: TYPES }
  validates :state, inclusion: { in: STATES }
  validates :idempotency_digest, :request_digest, presence: true, length: { is: 64 }
  validates :consent_digest, :claim_digest, length: { is: 64 }, allow_nil: true
  validates :version, numericality: { only_integer: true, greater_than: 0 }
  validates :expected_items, numericality: { only_integer: true, in: 0..25 }
  validates :finished_items, :failed_items, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_items, numericality: { only_integer: true, in: 1..25 }
  validates :max_source_urls, numericality: { only_integer: true, in: 1..75 }
  validates :max_attempts, numericality: { only_integer: true, in: 1..5 }
  validate :associations_share_tenant
  validate :consistent_counts

  before_validation :set_expiry, on: :create

  def terminal?
    state.in?(TERMINAL_STATES)
  end

  private

  def set_expiry
    self.expires_at ||= Time.current + RETENTION_PERIOD
  end

  def associations_share_tenant
    errors.add(:portal, 'must belong to the operation account') if portal && portal.account_id != account_id
    return if user.blank? || account.blank?
    return if AccountUser.exists?(account_id: account_id, user_id: user_id)

    errors.add(:user, 'must be a member of the operation account')
  end

  def consistent_counts
    return if [expected_items, finished_items, failed_items].any?(&:nil?)
    return if finished_items.between?(failed_items, expected_items)

    errors.add(:base, 'operation counts are inconsistent')
  end
end
