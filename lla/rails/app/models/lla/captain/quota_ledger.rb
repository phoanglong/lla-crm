# frozen_string_literal: true

class Lla::Captain::QuotaLedger < ApplicationRecord
  self.table_name = 'lla_captain_quota_ledgers'

  BUCKET = 'captain_responses'

  belongs_to :account, class_name: '::Account'
  has_many :reservations, class_name: 'Lla::Captain::QuotaReservation', inverse_of: :quota_ledger, dependent: :delete_all

  enum :reconciliation_state, { pending: 0, verified: 1, drifted: 2 }, prefix: :reconciliation

  validates :bucket, presence: true, length: { maximum: 64 }
  validates :period_start, :period_end, presence: true
  validates :limit_snapshot, :opening_consumed_units, :reserved_units, :consumed_units, :released_units,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :period_end_after_start

  def used_units
    opening_consumed_units + reserved_units + consumed_units
  end

  def available_units
    [limit_snapshot - used_units, 0].max
  end

  private

  def period_end_after_start
    return if period_start.blank? || period_end.blank? || period_end > period_start

    errors.add(:period_end, 'must be after period_start')
  end
end
