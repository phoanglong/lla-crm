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
    guard_installation_host!(canonical)
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

    # Fenced like every other transition: an administrator releasing a domain races
    # with whatever worker is mid-flight on it, and the loser must not write.
    previous = domain.state
    return domain unless domain.fenced_update({ state: 'removing', removal_requested_at: Time.current,
                                                version: domain.version + 1, last_error_code: nil },
                                              expected: { state: previous })

    Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
    emit_transition(domain, previous)
    Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'remove')
    domain
  end

  # Administrator-triggered reverification of a legacy import. Routing is left alone
  # on purpose: the domain keeps serving while the proof is collected, and only a
  # real, completed proof clears the flag. Idempotent — an in-flight reverification
  # returns the same operation.
  def request_reverify!(domain, now: Time.current)
    raise InvalidRequest, 'lla_custom_domain_reverify_not_applicable' unless reverifiable?(domain)

    # A repeat attempt mints fresh challenge material, and that is exactly what the
    # rotation budget bounds — otherwise an administrator could issue new nonces for
    # a domain forever, one per expiry window.
    rotate_challenge!(domain, 'lla_custom_domain_reverify_exhausted') unless domain.challenge_active?(now)
    Lla::CustomDomains::Telemetry.emit('reverify_requested', account_id: domain.account_id,
                                                             portal_id: domain.portal_id,
                                                             domain_id: domain.id, state: domain.state)
    Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'reverify')
  end

  def reverifiable?(domain)
    domain.present? && domain.active? && domain.legacy_import? && domain.reverify_required?
  end

  # `failed` is the documented terminal state for a claim whose proof never arrived.
  # Without this it would also be a dead end: the portal still stores the hostname,
  # so re-submitting the same value changes nothing, and the globally unique row
  # would block the hostname forever. A retry is a genuinely new attempt — the
  # version bump makes every operation still in flight for the old attempt stale, and
  # gives the ownership challenge a fresh, bounded rotation.
  def retryable?(domain)
    domain.present? && domain.state == 'failed'
  end

  def retry_verification!(domain)
    raise InvalidRequest, 'lla_custom_domain_retry_not_applicable' unless retryable?(domain)

    guard_installation_host!(domain.hostname)
    # Rotate first: if the budget is spent the domain must stay exactly where it was,
    # rather than being left mid-transition by a rejected retry.
    rotate_challenge!(domain, 'lla_custom_domain_retry_exhausted')
    previous = domain.state
    transition!(domain, { state: 'requested', version: domain.version + 1, last_error_code: nil,
                          ownership_verified_at: nil, activated_at: nil, removal_requested_at: nil },
                state: previous)
    emit_transition(domain, previous)
    transition!(domain, { state: 'ownership_pending' }, state: 'requested')
    emit_transition(domain, 'requested')
    Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'verify')
    domain
  end

  # Every transition below is a conditional write (`Domain#fenced_update`), so a
  # result computed against a row that has since moved writes nothing and returns
  # false. Callers must treat false as "discard this result", never as "retry the
  # write" — the row belongs to whoever moved it.
  #
  # A completed reverification is the only thing that turns a legacy import into a
  # proved domain. It never fabricates the original activation moment.
  def promote_legacy!(domain, now: Time.current)
    return false unless reverifiable?(domain)
    unless domain.fenced_update({ ownership_source: 'nonce_challenge', reverify_required: false,
                                  ownership_verified_at: now, activated_at: domain.activated_at || now,
                                  last_error_code: nil },
                                expected: { state: 'active', ownership_source: 'legacy_import',
                                            reverify_required: true })
      return false
    end

    Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
    Lla::CustomDomains::Telemetry.emit('reverify_succeeded', account_id: domain.account_id,
                                                             portal_id: domain.portal_id,
                                                             domain_id: domain.id, state: 'active')
    true
  end

  def mark_ownership_verified!(domain, now: Time.current)
    return false unless domain.state == 'ownership_pending'
    return false unless domain.fenced_update({ state: 'provisioning', ownership_verified_at: now,
                                               last_error_code: nil },
                                             expected: { state: 'ownership_pending' })

    emit_transition(domain, 'ownership_pending')
    Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'provision')
    true
  end

  def activate!(domain, resource_id:, status:, now: Time.current)
    return false unless domain.state == 'provisioning'
    unless domain.fenced_update({ state: 'active', activated_at: now, provider_synced_at: now,
                                  provider_resource_id: resource_id.presence,
                                  provider_status: status.presence,
                                  ownership_source: 'nonce_challenge', reverify_required: false,
                                  last_error_code: nil },
                                expected: { state: 'provisioning' })
      return false
    end

    Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
    emit_transition(domain, 'provisioning')
    true
  end

  # Returns false in both the "moved the domain to failed" and the "row moved on"
  # case, because no caller acts on the difference: `fail!` is the end of a result,
  # never the start of another write.
  def fail!(domain, code:)
    previous = domain.state
    return false unless domain.fenced_update({ state: 'failed', last_error_code: code.to_s.first(64) },
                                             expected: { state: previous })

    emit_transition(domain, previous, error_code: code)
    false
  end

  private

  attr_reader :portal

  def emit_transition(domain, previous_state, error_code: nil)
    Lla::CustomDomains::Telemetry.emit('lifecycle_transition', account_id: domain.account_id,
                                                               portal_id: domain.portal_id,
                                                               domain_id: domain.id,
                                                               provider: domain.provider,
                                                               previous_state: previous_state,
                                                               state: domain.state,
                                                               error_code: error_code)
  end

  # The installation's own hostnames already resolve to this application, so a proof
  # fetched over them would be served by this very app: a tenant could "prove"
  # ownership of the vendor's domain and then hold the globally unique hostname row
  # for it. They are not claimable at all.
  def guard_installation_host!(canonical)
    return unless Lla::CustomDomains::HostResolver.installation_host?(canonical)

    raise InvalidRequest, 'lla_custom_domain_installation_host'
  end

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
    # A legacy import carries provider evidence but no resource ID, so there is
    # nothing to tear down remotely and nothing to snapshot. Overwriting the row
    # would erase the only record that a remote object may still exist for the old
    # hostname, so the evidence is moved into a tombstone first.
    Lla::CustomDomains::TombstoneRecorder.record_removal!(domain)

    transition!(domain,
                { hostname: canonical, state: 'requested', version: domain.version + 1,
                  provider: default_provider,
                  provider_resource_id: nil, provider_status: nil, provider_synced_at: nil,
                  ownership_source: 'nonce_challenge', reverify_required: false,
                  ownership_verified_at: nil, activated_at: nil, removal_requested_at: nil,
                  last_error_code: nil, challenge_rotations: 0 },
                state: domain.state)
    Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
    domain
  end

  # Every *repeat* attempt on the same hostname rotates instead of re-issuing, so the
  # bounded rotation budget is what stops an administrator from minting fresh
  # challenge material indefinitely.
  def rotate_challenge!(domain, code)
    Lla::CustomDomains::OwnershipChallenge.rotate!(domain)
  rescue Lla::CustomDomains::OwnershipChallenge::RotationExhausted
    raise InvalidRequest, code
  rescue Lla::CustomDomains::OwnershipChallenge::Stale
    raise InvalidRequest, 'lla_custom_domain_conflict'
  end

  # A request-path transition: the caller is answering an administrator, so losing
  # the row to a concurrent writer is a conflict to report, not a result to discard.
  def transition!(domain, attributes, expected)
    return if domain.fenced_update(attributes, expected: expected)

    raise InvalidRequest, 'lla_custom_domain_conflict'
  end

  def start_ownership!(domain)
    Lla::CustomDomains::OwnershipChallenge.issue!(domain)
    transition!(domain, { state: 'ownership_pending' }, state: 'requested')
    emit_transition(domain, 'requested')
    Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'verify')
    domain
  end
end
