# frozen_string_literal: true

class Lla::Captain::QuotaReservation < ApplicationRecord
  self.table_name = 'lla_captain_quota_reservations'

  belongs_to :quota_ledger, class_name: 'Lla::Captain::QuotaLedger', inverse_of: :reservations

  enum :state, { reserved: 0, consumed: 1, released: 2, rejected: 3 }

  validates :idempotency_key_digest, presence: true, length: { is: 64 }, uniqueness: true
  validates :owner_token_digest, length: { is: 64 }, allow_nil: true
  validates :feature, :provider, :credential_source, :reason, presence: true
  validates :feature, :reason, length: { maximum: 128 }
  validates :provider, length: { maximum: 64 }
  validates :credential_source, length: { maximum: 32 }
  validates :units, :attempts, numericality: { only_integer: true, greater_than: 0 }
  validate :reserved_claim_is_complete

  delegate :account, to: :quota_ledger

  private

  def reserved_claim_is_complete
    return unless reserved?

    errors.add(:owner_token_digest, 'is required for a reservation') if owner_token_digest.blank?
    errors.add(:claimed_at, 'is required for a reservation') if claimed_at.blank?
  end
end
