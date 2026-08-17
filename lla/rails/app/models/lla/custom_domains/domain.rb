# frozen_string_literal: true

# Durable, tenant-bound lifecycle record for one customer supplied Help Center
# hostname. `portals.custom_domain` stays the user facing column; this row is the
# canonical state that public/dashboard host lookup and every provider call read.
class Lla::CustomDomains::Domain < ApplicationRecord
  self.table_name = 'lla_custom_domains'

  STATES = %w[requested ownership_pending provisioning active failed removing].freeze
  TERMINAL_STATES = %w[active failed].freeze
  PROVIDERS = %w[none cloudflare].freeze
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
