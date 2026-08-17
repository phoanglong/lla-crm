# frozen_string_literal: true

# Owns every custom-domain state transition for one portal.
#
#   requested -> ownership_pending -> provisioning -> active
#                                                  \-> failed
#   (any state) -> removing -> (row destroyed after provider teardown)
#
# A hostname is globally unique and bound to one tenant: another account can never
# claim, re-claim or take over a hostname that is already registered, and every
# repoint tears the previous remote resource down before the new one is built.
class Lla::CustomDomains::LifecycleService
  class InvalidRequest < StandardError
    attr_reader :code

    def initialize(code = 'lla_custom_domain_invalid_request')
      @code = code
      super(code)
    end
  end

  # rubocop:disable Style/OneClassPerFile -- both are the service's own error contract
  class Conflict < InvalidRequest
    def initialize(code = 'lla_custom_domain_taken')
      super
    end
  end

  # rubocop:enable Style/OneClassPerFile

  def initialize(portal:)
    @portal = portal
  end

  # Reconciles the lifecycle with the value now stored on `portals.custom_domain`.
  def synchronize!(hostname)
    canonical = hostname.presence && Lla::CustomDomains::HostCanonicalizer.call(hostname)
    return release! if canonical.blank?

    request!(canonical)
  end

  def request!(hostname)
    canonical = Lla::CustomDomains::HostCanonicalizer.call(hostname)
    guard_cross_tenant_claim!(canonical)

    domain = Lla::CustomDomains::Domain.find_by(portal_id: portal.id)
    return domain if domain&.hostname == canonical && domain.state != 'removing'

    domain = domain.present? ? repoint!(domain, canonical) : create_domain!(canonical)
    start_ownership!(domain)
  end

  def release!
    domain = Lla::CustomDomains::Domain.find_by(portal_id: portal.id)
    return if domain.blank?
    return domain if domain.state == 'removing'

    domain.update!(state: 'removing', removal_requested_at: Time.current, version: domain.version + 1,
                   last_error_code: nil)
    Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
    Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'remove')
    domain
  end

  def mark_ownership_verified!(domain, now: Time.current)
    return false unless domain.state == 'ownership_pending'

    domain.update!(state: 'provisioning', ownership_verified_at: now, last_error_code: nil)
    Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'provision')
    true
  end

  def activate!(domain, resource_id:, status:, now: Time.current)
    return false unless domain.state == 'provisioning'

    domain.update!(state: 'active', activated_at: now, provider_synced_at: now,
                   provider_resource_id: resource_id.presence, provider_status: status.presence,
                   ownership_source: 'nonce_challenge', reverify_required: false,
                   last_error_code: nil)
    Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
    true
  end

  def fail!(domain, code:)
    domain.update!(state: 'failed', last_error_code: code.to_s.first(64))
    false
  end

  private

  attr_reader :portal

  def guard_cross_tenant_claim!(canonical)
    holder = Lla::CustomDomains::Domain.find_by(hostname: canonical)
    return if holder.blank? || holder.portal_id == portal.id

    raise Conflict
  end

  def create_domain!(canonical)
    Lla::CustomDomains::Domain.create!(
      account_id: portal.account_id, portal_id: portal.id, hostname: canonical,
      state: 'requested', provider: default_provider,
      ownership_source: 'nonce_challenge', reverify_required: false
    )
  end

  # Provider choice is per account: without global egress, the capability, the
  # account consent and both secret references, the local adapter is selected.
  def default_provider
    Lla::CustomDomains::ProviderRegistry.default_provider(account: portal.account)
  end

  # Repointing is a teardown plus a fresh request: the previous remote resource is
  # scheduled for removal from a snapshot, and the version bump makes every result
  # still in flight for the old hostname detectably stale.
  def repoint!(domain, canonical)
    Lla::CustomDomains::OperationService.enqueue_teardown!(
      account_id: domain.account_id, hostname: domain.hostname, provider: domain.provider,
      provider_resource_id: domain.provider_resource_id, domain_version: domain.version
    )

    domain.update!(
      hostname: canonical, state: 'requested', version: domain.version + 1,
      provider: default_provider,
      provider_resource_id: nil, provider_status: nil, provider_synced_at: nil,
      ownership_source: 'nonce_challenge', reverify_required: false,
      ownership_verified_at: nil, activated_at: nil, removal_requested_at: nil,
      last_error_code: nil, challenge_rotations: 0
    )
    Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
    domain
  end

  def start_ownership!(domain)
    Lla::CustomDomains::OwnershipChallenge.issue!(domain)
    domain.update!(state: 'ownership_pending')
    Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'verify')
    domain
  end
end
