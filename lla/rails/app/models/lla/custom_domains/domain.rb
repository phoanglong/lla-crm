# frozen_string_literal: true

# Durable, tenant-bound lifecycle record for one customer supplied Help Center
# hostname. `portals.custom_domain` stays the user facing column; this row is the
# canonical state that public/dashboard host lookup and every provider call read.
#
# ## Lock order
#
# Exactly one order is used anywhere in this wave, without exception:
#
#   1. `lla_custom_domain_operations` — the lease row (`OperationService.hold!`),
#   2. `lla_custom_domains` — the domain row (`Domain.lock`).
#
# Nothing takes the domain first and then an operation, so two workers can never
# hold one and wait for the other. Callers that only need the domain (an
# administrator releasing it, the reconciler expiring a challenge) take just the
# second lock, which cannot close a cycle on its own.
class Lla::CustomDomains::Domain < ApplicationRecord
  self.table_name = 'lla_custom_domains'

  STATES = %w[requested ownership_pending provisioning active failed removing].freeze
  TERMINAL_STATES = %w[active failed].freeze
  PROVIDERS = %w[none cloudflare].freeze
  OWNERSHIP_SOURCES = %w[nonce_challenge legacy_import].freeze
  MAX_CHALLENGE_ROTATIONS = 10

  belongs_to :account, class_name: '::Account'
  belongs_to :portal, class_name: '::Portal'
  has_many :operations, class_name: 'Lla::CustomDomains::Operation',
                        foreign_key: :custom_domain_id, inverse_of: :domain, dependent: :nullify

  scope :active, -> { where(state: 'active') }
  scope :pending_removal, -> { where(state: 'removing') }

  validates :hostname, presence: true, uniqueness: true, length: { maximum: 253 }
  validates :state, inclusion: { in: STATES }
  validates :provider, inclusion: { in: PROVIDERS }
  validates :ownership_source, inclusion: { in: OWNERSHIP_SOURCES }
  validates :version, numericality: { only_integer: true, greater_than: 0 }
  validates :challenge_rotations, numericality: { only_integer: true, in: 0..MAX_CHALLENGE_ROTATIONS }
  validates :challenge_id_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :provider_resource_id, format: { with: /\A[A-Za-z0-9_-]{1,128}\z/ }, allow_nil: true
  validate :hostname_is_canonical
  validate :portal_belongs_to_account
  validate :provider_resource_requires_provider

  def active?
    state == 'active'
  end

  # The only way a worker result reaches this table.
  #
  # A result is computed from a row that was read at some earlier moment; between
  # that read and this write the row may have been repointed, released or already
  # advanced by whoever else was allowed to touch it. So the write carries its own
  # premise: the row must still be the exact tenant-bound identity the caller
  # decided from — same tenant, same id, same version, same hostname — and still be
  # in `expected` state. If it is not, zero rows change and the caller is told,
  # instead of overwriting a newer state with a stale conclusion.
  #
  # Callers that already hold the row lock get the same guarantee twice, which is
  # deliberate: the predicate is what makes correctness independent of whether the
  # caller remembered to lock.
  def fenced_update(attributes, expected: {})
    changed = self.class
                  .where(id: id, account_id: account_id, version: version, hostname: hostname)
                  .where(expected)
                  .update_all(attributes.merge(updated_at: Time.current)) # rubocop:disable Rails/SkipsModelValidations
    return false if changed.zero?

    reload
    true
  end

  # Imported from the pre-lifecycle `portals.custom_domain` column: it keeps
  # routing, but it carries no LLA ownership proof and still owes one.
  def legacy_import?
    ownership_source == 'legacy_import'
  end

  def challenge_active?(now = Time.current)
    challenge_id_digest.present? && challenge_expires_at.present? && challenge_expires_at > now
  end

  # Providers only ever see an opaque resource ID; the token itself never leaves
  # the secret reference resolver, so nothing here can leak a credential.
  def provider_adapter
    Lla::CustomDomains::ProviderRegistry.for(provider)
  end

  private

  def hostname_is_canonical
    return if hostname.blank?
    return if hostname == Lla::CustomDomains::HostCanonicalizer.call(hostname)

    errors.add(:hostname, 'must be a canonical DNS host')
  rescue Lla::CustomDomains::HostCanonicalizer::InvalidHost
    errors.add(:hostname, 'must be a canonical DNS host')
  end

  def portal_belongs_to_account
    return if portal.blank? || account_id.blank?
    return if portal.account_id == account_id

    errors.add(:portal, 'must belong to the custom domain account')
  end

  def provider_resource_requires_provider
    return if provider_resource_id.blank? || provider != 'none'

    errors.add(:provider_resource_id, 'requires a configured provider')
  end
end
