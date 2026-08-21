# frozen_string_literal: true

class Lla::Voice::RecordingConsent < ApplicationRecord
  self.table_name = 'lla_voice_recording_consents'

  METHODS = %w[agent_attestation].freeze
  DISCLOSURE_PATTERN = /\A[A-Za-z0-9_.:-]{1,64}\z/

  belongs_to :account, class_name: '::Account'
  belongs_to :inbox, class_name: '::Inbox'
  belongs_to :call, class_name: '::Call', inverse_of: :lla_recording_consent
  belongs_to :user, class_name: '::User', optional: true

  validates :capture_method, inclusion: { in: METHODS }
  validates :disclosure_version, format: { with: DISCLOSURE_PATTERN }
  validates :attestation_digest, :evidence_digest, :actor_reference_digest, length: { is: 64 }
  validates :captured_at, :client_attested_at, presence: true
  validate :inbox_shares_tenant
  validate :call_shares_tenant
  validate :user_is_live_member

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def inbox_shares_tenant
    errors.add(:inbox, 'must belong to the consent account') if inbox && inbox.account_id != account_id
  end

  def call_shares_tenant
    return unless call && (call.account_id != account_id || call.inbox_id != inbox_id)

    errors.add(:call, 'must belong to the consent account and inbox')
  end

  def user_is_live_member
    return if user.blank? || account.account_users.exists?(user_id: user.id)

    errors.add(:user, 'must be a live member of the consent account')
  end

  def prevent_mutation
    errors.add(:base, 'Recording consent evidence is immutable')
    throw(:abort)
  end
end
