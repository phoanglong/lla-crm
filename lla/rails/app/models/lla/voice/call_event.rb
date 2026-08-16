# frozen_string_literal: true

class Lla::Voice::CallEvent < ApplicationRecord
  self.table_name = 'lla_call_events'

  OUTCOMES = %w[pending applied duplicate stale rejected].freeze

  enum :provider, { twilio: 0, whatsapp: 1 }

  belongs_to :account, class_name: '::Account'
  belongs_to :inbox, class_name: '::Inbox'
  belongs_to :call, class_name: '::Call', optional: true, inverse_of: :lla_call_events

  validates :event_id_digest, :payload_digest, :event_type, :verified_at, presence: true
  validates :event_id_digest, :payload_digest, length: { is: 64 }
  validates :event_type, length: { maximum: 80 }
  validates :outcome, inclusion: { in: OUTCOMES }
  validate :associations_share_tenant

  private

  def associations_share_tenant
    errors.add(:inbox, 'must belong to the event account') if inbox && inbox.account_id != account_id
    return if call.blank?
    return if call.account_id == account_id && call.inbox_id == inbox_id

    errors.add(:call, 'must belong to the event account and inbox')
  end
end
