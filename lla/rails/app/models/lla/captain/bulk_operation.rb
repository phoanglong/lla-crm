# frozen_string_literal: true

class Lla::Captain::BulkOperation < ApplicationRecord
  self.table_name = 'lla_captain_bulk_operations'

  RETENTION_PERIOD = 30.days
  STATES = %w[pending processing completed failed].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :user, class_name: '::User'

  validates :key_digest, :request_digest, :resource_type, :action, presence: true
  validates :key_digest, :request_digest, length: { is: 64 }
  validates :state, inclusion: { in: STATES }
  validates :requested_count,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 100 }
  validates :processed_count, :error_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :consistent_counts

  before_validation :set_expiry, on: :create

  private

  def set_expiry
    self.expires_at ||= Time.current + RETENTION_PERIOD
  end

  def consistent_counts
    return if requested_count.blank? || processed_count.blank? || error_count.blank?
    return if processed_count <= requested_count && error_count <= requested_count &&
              processed_count + error_count <= requested_count

    errors.add(:base, 'operation counts are inconsistent')
  end
end
