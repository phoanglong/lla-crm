# frozen_string_literal: true

# Runs one leased custom-domain operation.
#
# Ordering is deliberate on every branch:
#
#   1. check the lease is still ours (cheap, unfenced) — bail out before any egress;
#   2. call the provider outside any transaction, and keep that call idempotent
#      because the lease may expire mid-flight;
#   3. apply the result inside `hold!`, i.e. a row-locked, token-checked
#      transaction that also re-checks `domain_version`.
#
# A worker whose lease was reclaimed therefore never mutates the domain, never
# enqueues a successor and never overwrites a terminal or cancelled row.
class Lla::CustomDomains::OperationExecutor
  Errors = Lla::CustomDomains::ProviderErrors
  Service = Lla::CustomDomains::OperationService

  def initialize(lease)
    @lease = lease
  end

  def perform
    return teardown_snapshot if operation.custom_domain_id.blank?

    domain = Lla::CustomDomains::Domain.find_by(id: operation.custom_domain_id)
    return stale!(domain) if operation.stale_for?(domain)

    run(domain)
  rescue Service::LeaseLost
    Lla::CustomDomains::Telemetry.emit('lease_lost', account_id: operation.account_id,
                                                     operation_id: operation.id,
                                                     operation_type: operation.operation_type)
    :lease_lost
  end

  private

  attr_reader :lease

  def run(domain)
    case operation.operation_type
    when 'verify' then run_verify(domain)
    when 'reverify' then run_reverify(domain)
    when 'provision' then run_provision(domain)
    when 'remove' then run_remove(domain)
    when 'reconcile' then run_reconcile(domain)
    end
  end

  def operation
    lease.operation
  end

  def lifecycle(domain)
    Lla::CustomDomains::LifecycleService.new(portal: domain.portal)
  end

  # Cheap pre-flight so a reclaimed worker stops before it opens a socket.
  def lease_held?
    Lla::CustomDomains::Operation.exists?(id: lease.id, state: 'claimed',
                                          claim_digest: Service.digest_for(lease.token))
  end

  # Fenced application of a result: row lock + constant-time token check + a fresh
  # staleness check, all inside one transaction.
  def apply!
    Lla::CustomDomains::Operation.transaction do
      Service.hold!(lease)
      yield
    end
  end

  def stale!(domain)
    # A domain already in `removing` is not stale for a remove operation: tearing
    # it down is exactly that operation's job.
    return run_remove(domain) if domain&.state == 'removing' && operation.operation_type == 'remove' && domain.hostname == operation.hostname

    Service.cancel_stale!(lease, code: 'lla_custom_domain_stale_operation')
  end

  def run_verify(domain)
    return Service.cancel_stale!(lease, code: 'lla_custom_domain_not_pending') unless domain.state == 'ownership_pending'
    raise Service::LeaseLost unless lease_held?

    case Lla::CustomDomains::OwnershipVerifier.verify(domain)
    when :verified then finish_verified(domain)
    when :deferred then Service.defer!(lease, code: 'lla_custom_domain_ownership_deferred')
    else retry_or_fail(domain, 'lla_custom_domain_ownership_unverified')
    end
  end

  def finish_verified(domain)
    apply! do
      fresh = domain.reload
      raise ActiveRecord::Rollback if operation.stale_for?(fresh) || fresh.state != 'ownership_pending'

      lifecycle(fresh).mark_ownership_verified!(fresh)
      Service.succeed!(lease)
    end
  end

  # Reverification runs against a domain that is still serving. Failure therefore
  # never changes routing: it records a stable code and leaves the flag set so an
  # administrator can trigger it again.
  def run_reverify(domain)
    return Service.cancel_stale!(lease, code: 'lla_custom_domain_reverify_not_applicable') unless lifecycle(domain).reverifiable?(domain)
    raise Service::LeaseLost unless lease_held?

    case Lla::CustomDomains::OwnershipVerifier.verify(domain)
    when :verified then finish_reverified(domain)
    when :deferred then Service.defer!(lease, code: 'lla_custom_domain_ownership_deferred')
    else record_reverify_failure(domain, 'lla_custom_domain_reverify_unverified')
    end
  end

  def finish_reverified(domain)
    apply! do
      fresh = domain.reload
      raise ActiveRecord::Rollback if operation.stale_for?(fresh)

      lifecycle(fresh).promote_legacy!(fresh)
      Service.succeed!(lease)
    end
  end

  def record_reverify_failure(domain, code)
    Service.fail!(lease, code: code)
    return unless operation.reload.state == 'dead_lettered'

    # Re-read and re-check: the domain may have been repointed or released while the
    # proof fetch was in flight, and a late result must never write onto it.
    fresh = Lla::CustomDomains::Domain.find_by(id: domain.id)
    return if fresh.blank? || operation.stale_for?(fresh)
    return unless lifecycle(fresh).reverifiable?(fresh)

    fresh.update!(last_error_code: code)
  end

  def run_provision(domain)
    return Service.cancel_stale!(lease, code: 'lla_custom_domain_not_provisioning') unless domain.state == 'provisioning'
    raise Service::LeaseLost unless lease_held?

    result = domain.provider_adapter.provision(domain)
    apply! do
      fresh = domain.reload
      raise ActiveRecord::Rollback if operation.stale_for?(fresh) || fresh.state != 'provisioning'

      lifecycle(fresh).activate!(fresh, resource_id: result[:resource_id], status: result[:status])
      Service.succeed!(lease)
    end
  rescue Errors::NotConfigured => e
    Service.defer!(lease, code: e.code)
  rescue Errors::Error => e
    retry_or_fail(domain, e.code)
  end

  def run_remove(domain)
    return Service.cancel_stale!(lease, code: 'lla_custom_domain_not_removing') unless domain.state == 'removing'
    raise Service::LeaseLost unless lease_held?

    domain.provider_adapter.teardown(domain.hostname, domain.provider_resource_id, account: domain.account)
    apply! { finish_removal(domain) }
  rescue Errors::NotConfigured => e
    Service.defer!(lease, code: e.code)
  rescue Errors::Error => e
    Service.fail!(lease, code: e.code)
  end

  # Success here means "this hostname no longer exists in LLA". The row is only
  # deleted under the exact predicate the operation was issued for, so a removal that
  # matches nothing is reported as stale instead of as a completed teardown — and no
  # tombstone is written for a row this operation did not actually remove.
  def finish_removal(domain)
    fresh = Lla::CustomDomains::Domain.lock.find_by(id: domain.id, state: 'removing', hostname: operation.hostname)
    if fresh.present?
      # Recorded before the row disappears: a legacy import may still own a remote
      # object whose ID LLA never learned, and that fact must survive the delete.
      Lla::CustomDomains::TombstoneRecorder.record_removal!(fresh)
      fresh.destroy!
      return Service.succeed!(lease)
    end

    # Already gone: another worker completed the same teardown.
    return Service.succeed!(lease) unless Lla::CustomDomains::Domain.exists?(id: domain.id)

    Service.cancel_stale!(lease, code: 'lla_custom_domain_stale_operation')
  end

  def run_reconcile(domain)
    raise Service::LeaseLost unless lease_held?

    result = domain.provider_adapter.check(domain)
    apply! do
      fresh = domain.reload
      raise ActiveRecord::Rollback if operation.stale_for?(fresh)

      fresh.update!(provider_status: result[:status], provider_synced_at: Time.current)
      Service.succeed!(lease)
    end
  rescue Errors::NotConfigured => e
    Service.defer!(lease, code: e.code)
  rescue Errors::Error => e
    Service.fail!(lease, code: e.code)
  end

  # The domain row is already gone; only the remote resource still has to be
  # released. Repeated runs are safe because provider teardown is idempotent.
  def teardown_snapshot
    return Service.cancel_stale!(lease, code: 'lla_custom_domain_stale_operation') unless operation.operation_type == 'remove'
    raise Service::LeaseLost unless lease_held?

    Lla::CustomDomains::ProviderRegistry.for(operation.provider)
                                        .teardown(operation.hostname, operation.provider_resource_id,
                                                  account: Account.find_by(id: operation.account_id))
    Service.succeed!(lease)
  rescue Errors::NotConfigured => e
    Service.defer!(lease, code: e.code)
  rescue Errors::Error => e
    Service.fail!(lease, code: e.code)
  end

  # The retry budget is spent. Moving the *domain* to `failed` is only correct while
  # the domain is still the one this operation was working on and still sits in the
  # state that operation owns — otherwise the row has moved on (repointed, released,
  # already active) and this result is merely late.
  def retry_or_fail(domain, code)
    Service.fail!(lease, code: code)
    return unless operation.reload.state == 'dead_lettered'

    fresh = Lla::CustomDomains::Domain.find_by(id: domain.id)
    return if fresh.blank? || operation.stale_for?(fresh)
    return unless fresh.state == Lla::CustomDomains::Operation::IN_FLIGHT_STATES[operation.operation_type]

    lifecycle(fresh).fail!(fresh, code: code)
  end
end
