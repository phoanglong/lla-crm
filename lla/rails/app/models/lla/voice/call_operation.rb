# frozen_string_literal: true

class Lla::Voice::CallOperation < ApplicationRecord
  self.table_name = 'lla_call_operations'

  STATES = %w[pending claimed succeeded failed compensating compensated].freeze
  CLAIM_TTL = 2.minutes
  MAX_ATTEMPTS = 20
  ACTIONS = %w[
    dial accept reject terminate permission_request provision teardown fetch_recording
    enable_calling disable_calling
  ].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :inbox, class_name: '::Inbox'
  belongs_to :call, class_name: '::Call', optional: true, inverse_of: :lla_call_operations

  validates :action, inclusion: { in: ACTIONS }
  validates :state, inclusion: { in: STATES }
  validates :idempotency_digest, :request_digest, :available_at, presence: true
  validates :idempotency_digest, :request_digest, length: { is: 64 }
  validates :claim_digest, :provider_request_id_digest, length: { is: 64 }, allow_nil: true
  validates :attempts, numericality: { only_integer: true, in: 0..20 }
  validate :associations_share_tenant

  def active_claim?(ttl: CLAIM_TTL)
    state == 'claimed' && claimed_at.present? && claimed_at > ttl.ago
  end

  def retry_delayed?
    state == 'failed' && available_at.present? && available_at > Time.current
  end

  def retry_exhausted?
    attempts >= MAX_ATTEMPTS
  end

  private

  def associations_share_tenant
    errors.add(:inbox, 'must belong to the operation account') if inbox && inbox.account_id != account_id
    return if call.blank?
    return if call.account_id == account_id && call.inbox_id == inbox_id

    errors.add(:call, 'must belong to the operation account and inbox')
  end
end
