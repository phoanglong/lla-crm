# frozen_string_literal: true

# Operator-visible evidence about one obligation LLA cannot discharge on its own,
# and one thing an operator may still have to do about it.
#
# Three kinds of evidence share the table:
#
# * a hostname that stopped being LLA's while a remote provider resource may still
#   exist (the pre-lifecycle import path never learned a resource ID, so LLA cannot
#   honestly claim it deleted anything remote);
# * a teardown that gave up while a *known* remote resource still exists — the one
#   case where the exact remote object is known, so the evidence carries it;
# * a legacy `portals.custom_domain` value the runtime canonicalizer refuses, which
#   stops routing at the lifecycle migration.
#
# Identity is `evidence_key`, never the hostname: the original value may be
# unrepresentable as a host, several portals in one account can lose the same
# hostname, and two different remote resources can exist for one hostname over time.
# Each of those is a separate item on the operator's work list.
#
# Two portal references, on purpose. `source_portal_id` is the immutable audit fact
# — which portal this evidence is about — and is what identity is computed from.
# `portal_id` is the live, tenant-checked foreign key, and is detached when the
# portal is deleted so the evidence outlives it without ever dangling.
class Lla::CustomDomains::Tombstone < ApplicationRecord
  self.table_name = 'lla_custom_domain_tombstones'

  LEGACY_RESOURCE_REASON = 'legacy_provider_resource_unknown'
  ABANDONED_REASON = 'provider_teardown_abandoned'
  REASONS = [LEGACY_RESOURCE_REASON, ABANDONED_REASON, 'legacy_hostname_unsupported',
             'legacy_hostname_duplicate', 'legacy_hostname_contested', 'legacy_hostname_unroutable'].freeze
  # Reasons that describe a remote resource: the hostname came from a lifecycle row,
  # so it exists and is canonical by construction.
  RESOURCE_REASONS = [LEGACY_RESOURCE_REASON, ABANDONED_REASON].freeze
  # Reasons that describe a rejected legacy value: the portal and a reference to the
  # exact original bytes are what an operator needs, and the hostname may not exist.
  # `legacy_hostname_contested` is the cross-tenant case: two accounts held values
  # that collapse to one hostname and none of them was the value that actually
  # routed, so the migration gives the hostname to nobody and tells both.
  # `legacy_hostname_unroutable` is a value that only becomes its hostname through
  # unicode/IDNA folding, so it could never have been the Host of a request and is
  # not evidence of ownership of anything.
  DROPPED_VALUE_REASONS = %w[legacy_hostname_unsupported legacy_hostname_duplicate
                             legacy_hostname_contested legacy_hostname_unroutable].freeze
  STATES = %w[manual_adoption_required resolved].freeze
  PREVIEW_LIMIT = 200

  belongs_to :account, class_name: '::Account'
  belongs_to :portal, class_name: '::Portal', optional: true

  scope :outstanding, -> { where(state: 'manual_adoption_required') }

  before_validation :assign_evidence_key

  validates :hostname, length: { maximum: 253 }, format: { without: /[[:space:][:cntrl:]]/ },
                       allow_nil: true
  validates :evidence_key, presence: true, length: { maximum: 128 },
                           format: { with: /\A[a-z0-9_.:-]+\z/ }
  validates :source_value_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :provider_resource_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :provider_resource_id, format: { with: /\A[A-Za-z0-9_-]{1,128}\z/ }, allow_nil: true
  validates :source_value_preview, length: { maximum: 253 }, format: { without: /[[:cntrl:]]/ },
                                   allow_nil: true
  validates :reason, inclusion: { in: REASONS }
  validates :state, inclusion: { in: STATES }
  validates :provider, inclusion: { in: Lla::CustomDomains::Domain::PROVIDERS }
  validates :provider_status_hint, length: { maximum: 64 }, allow_nil: true
  validates :resolved_by_reference, format: { with: /\A[A-Za-z0-9_.:-]{1,64}\z/ }, allow_nil: true
  validate :hostname_is_canonical
  validate :evidence_is_actionable
  validate :portal_reference_is_the_source_portal
  validate :source_portal_is_this_tenant

  # Identity of one piece of evidence. Bounded by construction: the variable part is
  # a digest prefix, never the value itself.
  #
  # What identifies an item is what an operator would have to fix separately:
  #
  # * a rejected legacy value belongs to one portal — several portals in one account
  #   can lose the same hostname, and each is its own item;
  # * an abandoned teardown belongs to one remote object at one provider — a second
  #   resource on the same hostname is a second object to delete, even if the item
  #   for the first one is already resolved;
  # * a legacy import with an unknown resource can only be identified by its
  #   hostname, which is globally unique, so recording it twice is the same item.
  # `facts` accepts `:source_portal_id`, `:source_value_digest`, `:provider`,
  # `:provider_resource_digest` and `:hostname` — each reason uses exactly the ones
  # that identify it, and ignores the rest.
  def self.evidence_key_for(reason:, **facts)
    scope, fingerprint = case reason
                         when *DROPPED_VALUE_REASONS
                           [facts[:source_portal_id], facts[:source_value_digest]]
                         when ABANDONED_REASON
                           [facts[:provider].presence || 'none', facts[:provider_resource_digest]]
                         else
                           [nil, Digest::SHA256.hexdigest(facts[:hostname].to_s)]
                         end
    "#{reason}:#{scope.presence || 0}:#{fingerprint.to_s[0, 32]}"
  end

  # The fingerprint of a remote resource identifier. Only the fingerprint is ever
  # used for identity or telemetry; the identifier itself lives in its own column.
  def self.resource_digest_for(provider_resource_id)
    return if provider_resource_id.blank?

    Digest::SHA256.hexdigest(provider_resource_id.to_s)
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

    self.evidence_key = self.class.evidence_key_for(reason: reason, provider: provider,
                                                    source_portal_id: source_portal_id,
                                                    hostname: hostname,
                                                    source_value_digest: source_value_digest,
                                                    provider_resource_digest: provider_resource_digest)
  end

  def hostname_is_canonical
    return if hostname.blank?
    return unless reason.in?(RESOURCE_REASONS)
    return if hostname == Lla::CustomDomains::HostCanonicalizer.canonicalize(hostname)

    errors.add(:hostname, 'must be a canonical DNS host')
  end

  # Evidence nobody can act on is not evidence: a dropped legacy value must name the
  # portal and carry a reference to the exact original, evidence about a remote
  # resource must name the hostname, and an abandoned teardown must name the exact
  # remote object it abandoned.
  def evidence_is_actionable
    if reason.in?(DROPPED_VALUE_REASONS)
      errors.add(:source_portal_id, 'is required to name the portal an operator must fix') if source_portal_id.blank?
      errors.add(:source_value_digest, 'is required to identify the rejected value') if source_value_digest.blank?
      errors.add(:source_value_preview, 'is required to describe the rejected value') if source_value_preview.blank?
    elsif reason.in?(RESOURCE_REASONS) && hostname.blank?
      errors.add(:hostname, 'is required to name the remote resource')
    end
    abandoned_resource_is_named
  end

  def abandoned_resource_is_named
    return unless reason == ABANDONED_REASON

    errors.add(:provider, 'must be the provider the abandoned resource lives at') if provider == 'none'
    return if provider_resource_id.present? && provider_resource_digest.present?

    errors.add(:provider_resource_id, 'is required to name the abandoned remote resource')
  end

  # The live reference may be absent — the portal can be deleted — but while it is
  # set it is the portal the evidence was recorded for, never another one.
  def portal_reference_is_the_source_portal
    return if portal_id.blank? || portal_id == source_portal_id

    errors.add(:portal_id, 'must be the portal the evidence was recorded for')
  end

  # `source_portal_id` deliberately carries no foreign key: it has to outlive the
  # portal. While the portal still exists, the tenant boundary is enforced twice over
  # — by the composite foreign key on the live reference, and here.
  def source_portal_is_this_tenant
    return if source_portal_id.blank? || account_id.blank?

    owner = ::Portal.where(id: source_portal_id).pick(:account_id)
    return if owner == account_id
    # The portal may legitimately be gone — that is the whole point of an immutable
    # audit reference — but only for a row that already exists. At creation the
    # portal has to be here, and has to be ours.
    return if owner.nil? && persisted?

    errors.add(:source_portal_id, 'must be a portal of this account')
  end
end
