# frozen_string_literal: true

# Runs one leased custom-domain operation.
#
# Ordering is deliberate on every branch:
#
#   1. check the lease is still ours (cheap, unfenced) — bail out before any egress;
#   2. call the provider outside any transaction, and keep that call idempotent
#      because the lease may expire mid-flight;
#   3. apply the result as one atomic fenced write.
#
# ## What "fenced" means here
#
# The provider call takes real time, and the domain is a shared row: an
# administrator can release or repoint it, and the reconciler can hand the work to
# a successor, while the call is in flight. So applying a result is not "check then
# write" — it is a single transaction that, in the documented lock order
# (`Domain` lock-order note: operation row first, then domain row):
#
#   * re-reads the operation `FOR UPDATE` and compares the lease token
#     (`OperationService.hold!`),
#   * re-reads the domain `FOR UPDATE`, bound to the operation's tenant, and proves
#     it is still the exact `(id, account_id, version, hostname)` the operation was
#     issued for,
#   * performs the lifecycle write as a conditional update on that same identity
#     plus the expected state (`Domain#fenced_update`),
#   * and only then finalizes the operation.
#
# Any of those failing aborts the whole transaction. A worker that lost its lease,
# or whose domain moved after the provider call, therefore performs **zero domain
# mutation** and **never marks its operation succeeded** — it cancels itself as
# stale instead.
class Lla::CustomDomains::OperationExecutor
  # The domain is no longer the row this operation was issued for. Raised inside the
  # fenced transaction, so nothing this worker computed is written.
  class DomainMoved < StandardError; end

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
    emit_worker_event('lease_lost')
    :lease_lost
  rescue DomainMoved
    emit_worker_event('domain_moved')
    discard_stale_result
  end

  private

  attr_reader :lease

  def emit_worker_event(event)
    Lla::CustomDomains::Telemetry.emit(event, account_id: operation.account_id, operation_id: operation.id,
                                              operation_type: operation.operation_type)
  end

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
    Lla::CustomDomains::Operation.exists?(id: lease.id, state: 'claimed', claim_digest: Service.digest_for(lease.token))
  end

  # One atomic fenced result. Locks are taken in the single documented order —
  # operation row, then domain row — so two workers on the same domain can never
  # deadlock against each other.
  def apply!(domain = nil)
    # `requires_new` so the fence is a real rollback boundary even when this runs
    # inside an outer transaction: a lost lease must undo the lifecycle write, not
    # merely stop the next statement.
    Lla::CustomDomains::Operation.transaction(requires_new: true) do
      Service.hold!(lease)
      yield(domain && fenced_domain!(domain))
    end
  end

  # The common shape of a successful branch: one fenced conditional write that must
  # either happen exactly as issued or not at all. A falsey predicate means the row
  # moved between the provider call and the write, so the whole transaction — the
  # lifecycle write *and* the operation finalization — is discarded.
  def apply_succeeding!(domain)
    apply!(domain) do |fresh|
      raise DomainMoved unless yield(fresh)

      Service.succeed!(lease)
    end
  end

  # The provider call is the only place egress can fail. "Not configured" is not a
  # failure of this attempt — the capability is off, so the work waits instead of
  # burning retry budget against a dead adapter. `retry_on` is the domain whose
  # retry budget a real provider error should spend; without it the failure is the
  # operation's alone.
  def with_provider_errors(retry_on: nil)
    yield
  rescue Errors::NotConfigured => e
    Service.defer!(lease, code: e.code)
  rescue Errors::Error => e
    retry_on ? retry_or_fail(retry_on, e.code) : Service.fail!(lease, code: e.code)
  end

  # The domain row, locked, and proved to still be the exact tenant-bound row this
  # operation was issued for.
  def fenced_domain!(domain)
    fresh = Lla::CustomDomains::Domain.lock.find_by(id: domain.id, account_id: operation.account_id)
    raise DomainMoved if operation.stale_for?(fresh)

    fresh
  end

  # The result is worthless and the operation must not look successful. Cancelling
  # is a compare-and-set on the operation alone, so it is safe after the fenced
  # transaction rolled back.
  def discard_stale_result
    Service.cancel_stale!(lease, code: 'lla_custom_domain_stale_operation')
    :stale
  rescue Service::LeaseLost
    :lease_lost
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
    apply_succeeding!(domain) do |fresh|
      fresh.state == 'ownership_pending' && lifecycle(fresh).mark_ownership_verified!(fresh)
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
    apply_succeeding!(domain) { |fresh| lifecycle(fresh).promote_legacy!(fresh) }
  end

  # Reverification failure never changes routing: it records a stable code on a
  # domain that is still serving, so the write is fenced but the outcome is metadata.
  def record_reverify_failure(domain, code)
    fenced_failure(domain, code) do |fresh|
      next unless lifecycle(fresh).reverifiable?(fresh)

      fresh.fenced_update({ last_error_code: code }, expected: { state: 'active' })
    end
  end

  def run_provision(domain)
    return Service.cancel_stale!(lease, code: 'lla_custom_domain_not_provisioning') unless domain.state == 'provisioning'
    raise Service::LeaseLost unless lease_held?

    with_provider_errors(retry_on: domain) do
      result = domain.provider_adapter.provision(domain)
      apply_succeeding!(domain) do |fresh|
        fresh.state == 'provisioning' &&
          lifecycle(fresh).activate!(fresh, resource_id: result[:resource_id], status: result[:status])
      end
    end
  end

  def run_remove(domain)
    return Service.cancel_stale!(lease, code: 'lla_custom_domain_not_removing') unless domain.state == 'removing'
    raise Service::LeaseLost unless lease_held?

    with_provider_errors do
      domain.provider_adapter.teardown(domain.hostname, domain.provider_resource_id, account: domain.account)
      apply! { finish_removal(domain) }
    end
  end

  # Success here means "this hostname no longer exists in LLA". The row is only
  # deleted under the exact predicate the operation was issued for, so a removal that
  # matches nothing is reported as stale instead of as a completed teardown — and no
  # tombstone is written for a row this operation did not actually remove.
  def finish_removal(domain)
    fresh = Lla::CustomDomains::Domain.lock.find_by(id: domain.id, account_id: operation.account_id,
                                                    state: 'removing', hostname: operation.hostname)
    if fresh.present?
      # Recorded before the row disappears: a legacy import may still own a remote
      # object whose ID LLA never learned, and that fact must survive the delete.
      Lla::CustomDomains::TombstoneRecorder.record_removal!(fresh)
      fresh.destroy!
      return Service.succeed!(lease)
    end

    # Already gone: another worker completed the same teardown.
    return Service.succeed!(lease) unless Lla::CustomDomains::Domain.exists?(id: domain.id,
                                                                             account_id: operation.account_id)

    Service.cancel_stale!(lease, code: 'lla_custom_domain_stale_operation')
  end

  def run_reconcile(domain)
    raise Service::LeaseLost unless lease_held?

    with_provider_errors do
      result = domain.provider_adapter.check(domain)
      apply_succeeding!(domain) do |fresh|
        fresh.fenced_update(provider_status: result[:status], provider_synced_at: Time.current)
      end
    end
  end

  # The domain row is already gone; only the remote resource still has to be
  # released. Repeated runs are safe because provider teardown is idempotent.
  def teardown_snapshot
    return Service.cancel_stale!(lease, code: 'lla_custom_domain_stale_operation') unless operation.operation_type == 'remove'
    raise Service::LeaseLost unless lease_held?

    with_provider_errors do
      Lla::CustomDomains::ProviderRegistry.for(operation.provider)
                                          .teardown(operation.hostname, operation.provider_resource_id,
                                                    account: Account.find_by(id: operation.account_id))
      Service.succeed!(lease)
    end
  end

  # The retry budget is spent. Moving the *domain* to `failed` is only correct while
  # the domain is still the one this operation was working on and still sits in the
  # state that operation owns — otherwise the row has moved on (repointed, released,
  # already active) and this result is merely late.
  def retry_or_fail(domain, code)
    fenced_failure(domain, code) do |fresh|
      next unless fresh.state == Lla::CustomDomains::Operation::IN_FLIGHT_STATES[operation.operation_type]

      lifecycle(fresh).fail!(fresh, code: code)
    end
  end

  # Failure metadata is a domain write like any other, so it takes the same two
  # locks in the same order and the same conditional write. The operation is
  # finalized inside that transaction too: a worker cannot record "this attempt
  # failed" and then lose the race to describe why. The block runs only for the
  # terminal attempt, on a domain that is still the one this operation was issued
  # for — a retry that will run again writes nothing to the domain.
  def fenced_failure(domain, code)
    Lla::CustomDomains::Operation.transaction(requires_new: true) do
      Service.hold!(lease)
      fresh = Lla::CustomDomains::Domain.lock.find_by(id: domain.id, account_id: operation.account_id)
      result = Service.fail!(lease, code: code)
      next if fresh.blank? || operation.stale_for?(fresh) || result.state != 'dead_lettered'

      yield(fresh)
    end
  end
end
