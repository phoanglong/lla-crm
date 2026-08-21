# frozen_string_literal: true

class Lla::Knowledge::GenerationOutbox < ApplicationRecord
  self.table_name = 'lla_knowledge_generation_outboxes'

  STATES = %w[pending claimed delivered failed cancelled].freeze
  EVENT_TYPES = %w[plan_generation write_article translate_article rebuild_index reconcile].freeze

  belongs_to :operation, class_name: 'Lla::Knowledge::GenerationOperation',
                         foreign_key: :generation_operation_id, inverse_of: :outboxes
  belongs_to :account, class_name: '::Account'
  belongs_to :portal, class_name: '::Portal'

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :state, inclusion: { in: STATES }
  validates :idempotency_digest, :payload_digest, presence: true, length: { is: 64 }
  validates :payload_ciphertext, presence: true
  validates :claim_digest, length: { is: 64 }, allow_nil: true
  validates :attempts, numericality: { only_integer: true, in: 0..5 }
  validates :available_at, presence: true
  validate :associations_share_tenant

  def payload=(value)
    self.payload_digest = Lla::Knowledge::PayloadCipher.digest(value)
    self.payload_ciphertext = Lla::Knowledge::PayloadCipher.encrypt(value)
  end

  def payload
    Lla::Knowledge::PayloadCipher.decrypt(payload_ciphertext)
  end

  private

  def associations_share_tenant
    expected = [account_id, portal_id]
    errors.add(:operation, 'must share the outbox tenant and portal') if operation && expected != [operation.account_id, operation.portal_id]
    errors.add(:portal, 'must belong to the outbox account') if portal && portal.account_id != account_id
  end
end
