# frozen_string_literal: true

# Durable operation/outbox row for a single custom-domain side effect. Provider
# identity and hostname are snapshotted so a teardown still runs after the domain
# row is gone, and `domain_version` makes every late result detectably stale.
class Lla::CustomDomains::Operation < ApplicationRecord
  self.table_name = 'lla_custom_domain_operations'

  TYPES = %w[provision verify remove reconcile].freeze
  STATES = %w[pending claimed succeeded failed dead_lettered cancelled].freeze
  TERMINAL_STATES = %w[succeeded dead_lettered cancelled].freeze
  RETENTION_PERIOD = 30.days
  MAX_ATTEMPTS = 5
  BACKOFF_BASE = 30.seconds

  belongs_to :account, class_name: '::Account'
  belongs_to :domain, class_name: 'Lla::CustomDomains::Domain',
                      foreign_key: :custom_domain_id, inverse_of: :operations, optional: true

  scope :dispatchable, ->(now = Time.current) { where(state: 'pending').where(available_at: ..now) }

  validates :operation_type, inclusion: { in: TYPES }
  validates :state, inclusion: { in: STATES }
  validates :provider, inclusion: { in: Lla::CustomDomains::Domain::PROVIDERS }
  validates :idempotency_digest, :request_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :claim_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :hostname, presence: true, length: { maximum: 253 }
  validates :provider_resource_id, format: { with: /\A[A-Za-z0-9_-]{1,128}\z/ }, allow_nil: true
  validates :domain_version, numericality: { only_integer: true, greater_than: 0 }
  validates :max_attempts, numericality: { only_integer: true, in: 1..MAX_ATTEMPTS }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :attempts_within_budget
  validate :domain_shares_tenant

  before_validation :set_defaults, on: :create

  def terminal?
    state.in?(TERMINAL_STATES)
  end

  # A result is only allowed to mutate the domain when the domain has not moved on
  # since the operation was enqueued.
  def stale_for?(current_domain)
    current_domain.blank? ||
      current_domain.id != custom_domain_id ||
      current_domain.version != domain_version ||
      current_domain.hostname != hostname
  end

  def next_available_at(now = Time.current)
    now + (BACKOFF_BASE * (2**[attempts - 1, 0].max))
  end

  private

  def set_defaults
    self.available_at ||= Time.current
    self.expires_at ||= Time.current + RETENTION_PERIOD
  end

  def attempts_within_budget
    return if attempts.blank? || max_attempts.blank?
    return if attempts <= max_attempts

    errors.add(:attempts, 'exceeds the operation retry budget')
  end

  def domain_shares_tenant
    return if domain.blank?
    return if domain.account_id == account_id

    errors.add(:domain, 'must belong to the operation account')
  end
end
