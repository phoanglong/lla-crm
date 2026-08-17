# frozen_string_literal: true

# Operator-visible evidence about one hostname that left LLA and one thing an
# operator may still have to do about it.
#
# Two kinds of evidence share the table:
#
# * a hostname that stopped being LLA's while a remote provider resource may still
#   exist (the pre-lifecycle import path never learned a resource ID, so LLA cannot
#   honestly claim it deleted anything remote);
# * a legacy `portals.custom_domain` value the runtime canonicalizer refuses, which
#   stops routing at the lifecycle migration.
#
# The second kind is why `hostname` is nullable and why identity is `evidence_key`
# rather than the hostname: the original value may be unrepresentable as a host, and
# several portals in one account can lose the same hostname — each of them is a
# separate item on the operator's work list.
class Lla::CustomDomains::Tombstone < ApplicationRecord
  self.table_name = 'lla_custom_domain_tombstones'

  REASONS = %w[legacy_provider_resource_unknown provider_teardown_abandoned
               legacy_hostname_unsupported legacy_hostname_duplicate].freeze
  # Reasons that describe a live remote resource: the hostname came from a lifecycle
  # row, so it exists and is canonical by construction.
  RESOURCE_REASONS = %w[legacy_provider_resource_unknown provider_teardown_abandoned].freeze
  # Reasons that describe a rejected legacy value: the portal and a reference to the
  # exact original bytes are what an operator needs, and the hostname may not exist.
  DROPPED_VALUE_REASONS = %w[legacy_hostname_unsupported legacy_hostname_duplicate].freeze
  STATES = %w[manual_adoption_required resolved].freeze
  PREVIEW_LIMIT = 200

  belongs_to :account, class_name: '::Account'

  scope :outstanding, -> { where(state: 'manual_adoption_required') }

  before_validation :assign_evidence_key

  validates :hostname, length: { maximum: 253 }, format: { without: /[[:space:][:cntrl:]]/ },
                       allow_nil: true
  validates :evidence_key, presence: true, length: { maximum: 128 },
                           format: { with: /\A[a-z0-9_.:-]+\z/ }
  validates :source_value_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :source_value_preview, length: { maximum: 253 }, format: { without: /[[:cntrl:]]/ },
                                   allow_nil: true
  validates :reason, inclusion: { in: REASONS }
  validates :state, inclusion: { in: STATES }
  validates :provider, inclusion: { in: Lla::CustomDomains::Domain::PROVIDERS }
  validates :provider_status_hint, length: { maximum: 64 }, allow_nil: true
  validates :resolved_by_reference, format: { with: /\A[A-Za-z0-9_.:-]{1,64}\z/ }, allow_nil: true
  validate :hostname_is_canonical
  validate :evidence_is_actionable

  # Identity of one piece of evidence. Bounded by construction: the variable part is
  # a digest prefix, never the value itself.
  #
  # The portal is part of the identity only where it has to be. A rejected legacy
  # value belongs to one portal, and several portals in one account can lose the
  # same hostname — those are separate items. A remote resource belongs to a
  # hostname, which is globally unique, so recording it twice is the same item.
  def self.evidence_key_for(reason:, portal_id: nil, digest: nil, hostname: nil)
    fingerprint = digest.presence || Digest::SHA256.hexdigest(hostname.to_s)
    scope = DROPPED_VALUE_REASONS.include?(reason) ? portal_id : nil
    "#{reason}:#{scope || 0}:#{fingerprint[0, 32]}"
  end

  # Printable, bounded and never blank, so the original value can be recognised
  # without ever being stored somewhere that treats it as a hostname.
  def self.safe_preview(raw)
    printable = raw.to_s.dup.force_encoding(Encoding::BINARY)
                   .gsub(/[[:space:]]/n, '_')
                   .gsub(/[^\x20-\x7E]/n, '?')
    suffix = printable.bytesize > PREVIEW_LIMIT ? "...+#{printable.bytesize - PREVIEW_LIMIT}" : ''
    value = "#{printable[0, PREVIEW_LIMIT]}#{suffix}"
    (value.empty? ? '(empty)' : value).force_encoding(Encoding::UTF_8)
  end

  def resolve!(reference:, now: Time.current)
    update!(state: 'resolved', resolved_at: now, resolved_by_reference: reference)
  end

  private

  def assign_evidence_key
    return if evidence_key.present? || reason.blank?

    self.evidence_key = self.class.evidence_key_for(reason: reason, portal_id: portal_id,
                                                    digest: source_value_digest, hostname: hostname)
  end

  def hostname_is_canonical
    return if hostname.blank?
    return unless reason.in?(RESOURCE_REASONS)
    return if hostname == Lla::CustomDomains::HostCanonicalizer.canonicalize(hostname)

    errors.add(:hostname, 'must be a canonical DNS host')
  end

  # Evidence nobody can act on is not evidence: a dropped legacy value must name the
  # portal and carry a reference to the exact original, and evidence about a remote
  # resource must name the hostname that resource belongs to.
  def evidence_is_actionable
    if reason.in?(DROPPED_VALUE_REASONS)
      errors.add(:portal_id, 'is required to name the portal an operator must fix') if portal_id.blank?
      errors.add(:source_value_digest, 'is required to identify the rejected value') if source_value_digest.blank?
      errors.add(:source_value_preview, 'is required to describe the rejected value') if source_value_preview.blank?
    elsif reason.in?(RESOURCE_REASONS) && hostname.blank?
      errors.add(:hostname, 'is required to name the remote resource')
    end
  end
end
