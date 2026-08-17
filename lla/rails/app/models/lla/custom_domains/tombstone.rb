# frozen_string_literal: true

# Operator-visible evidence that a hostname left LLA while a remote provider
# resource may still exist.
#
# The pre-lifecycle import path never learned a provider resource ID, so LLA cannot
# honestly claim it deleted anything remote. Rather than silently dropping that
# fact — or, worse, calling a delete without an ID — the removal records a tombstone
# that outlives both the domain row and the operation retention window.
class Lla::CustomDomains::Tombstone < ApplicationRecord
  self.table_name = 'lla_custom_domain_tombstones'

  REASONS = %w[legacy_provider_resource_unknown provider_teardown_abandoned
               legacy_hostname_unsupported legacy_hostname_duplicate].freeze
  # Reasons whose hostname came from a live lifecycle row, and is therefore
  # canonical by construction. The two `legacy_hostname_*` reasons are the opposite
  # case: they exist precisely to record a value the canonicalizer refused, so
  # requiring it to be canonical would throw away the evidence.
  CANONICAL_REASONS = %w[legacy_provider_resource_unknown provider_teardown_abandoned].freeze
  STATES = %w[manual_adoption_required resolved].freeze

  belongs_to :account, class_name: '::Account'

  scope :outstanding, -> { where(state: 'manual_adoption_required') }

  validates :hostname, presence: true, length: { maximum: 253 },
                       format: { without: /[[:space:][:cntrl:]]/ }
  validates :reason, inclusion: { in: REASONS }
  validates :state, inclusion: { in: STATES }
  validates :provider, inclusion: { in: Lla::CustomDomains::Domain::PROVIDERS }
  validates :provider_status_hint, length: { maximum: 64 }, allow_nil: true
  validates :resolved_by_reference, format: { with: /\A[A-Za-z0-9_.:-]{1,64}\z/ }, allow_nil: true
  validate :hostname_is_canonical

  def resolve!(reference:, now: Time.current)
    update!(state: 'resolved', resolved_at: now, resolved_by_reference: reference)
  end

  private

  def hostname_is_canonical
    return if hostname.blank?
    return unless reason.in?(CANONICAL_REASONS)
    return if hostname == Lla::CustomDomains::HostCanonicalizer.canonicalize(hostname)

    errors.add(:hostname, 'must be a canonical DNS host')
  end
end
