# frozen_string_literal: true

# Periodic safety net for the custom-domain operation queue.
#
# Beyond re-dispatching waiting work and reclaiming claims abandoned by a dead
# worker, it owns the *recovery contract*: an operation that reached a terminal
# state without finishing its job either gets exactly one bounded successor, or the
# domain is moved to an explicit, operator-visible outcome. Nothing is allowed to
# sit in `ownership_pending`, `provisioning` or `removing` forever with no runnable
# work behind it.
class Lla::CustomDomains::ReconciliationJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100
  STUCK_REMOVAL_AFTER = 1.hour
  # Terminal rows are kept for a while past retention so the cancellation that
  # ended them stays auditable instead of vanishing in the same tick.
  PURGE_GRACE = 7.days
  IN_FLIGHT_STATES = Lla::CustomDomains::Operation::IN_FLIGHT_STATES
  ABANDON_CODES = {
    'verify' => 'lla_custom_domain_ownership_abandoned',
    'provision' => 'lla_custom_domain_provisioning_abandoned'
  }.freeze
  MANUAL_INTERVENTION_CODE = 'lla_custom_domain_teardown_manual_intervention'
  CHALLENGE_EXPIRED_CODE = 'lla_custom_domain_challenge_expired'

  def perform(now: Time.current)
    expire_operations(now)
    redispatch_waiting(now)
    reclaim_stale_claims(now)
    recover_terminal_operations(now)
    recover_orphan_teardowns(now)
    expire_challenges(now)
    rearm_stuck_removals(now)
    purge_expired_operations(now)
    report_health(now)
  end

  private

  def operations
    Lla::CustomDomains::Operation
  end

  # Past its retention window: stop touching the provider, record it and move on.
  # The CAS predicate means a worker that finalized first is never overwritten.
  def expire_operations(now)
    operations.runnable.where(expires_at: ...now).limit(BATCH_SIZE).find_each do |operation|
      Lla::CustomDomains::OperationService.expire!(operation, code: 'lla_custom_domain_operation_expired', now: now)
    end
  end

  def redispatch_waiting(now)
    operations.dispatchable(now).limit(BATCH_SIZE).pluck(:id).each do |id|
      Lla::CustomDomains::OperationDispatchJob.perform_later(id)
    end
  end

  # A claim older than CLAIM_TIMEOUT belongs to a worker that never came back.
  # Dispatch re-runs the CAS claim, which is what makes the takeover safe.
  def reclaim_stale_claims(now)
    operations.stale_claims(now).where(expires_at: now..).limit(BATCH_SIZE).pluck(:id).each do |id|
      Lla::CustomDomains::OperationDispatchJob.perform_later(id)
    end
  end

  # Terminal-but-unfinished work: one bounded successor, or an explicit outcome.
  def recover_terminal_operations(now)
    operations.where(state: %w[cancelled dead_lettered])
              .where.not(custom_domain_id: nil)
              .order(id: :desc)
              .limit(BATCH_SIZE)
              .find_each { |operation| recover(operation, now) }
  end

  def recover(operation, now)
    expected_state = IN_FLIGHT_STATES[operation.operation_type]
    return if expected_state.blank?

    domain = operation.domain
    return if domain.blank? || domain.state != expected_state || domain.version != operation.domain_version
    return if runnable_work?(domain, operation.operation_type)

    successor = Lla::CustomDomains::OperationService.enqueue_recovery!(operation, now: now)
    abandon(domain, operation) if successor.blank?
  end

  def runnable_work?(domain, operation_type)
    operations.runnable.exists?(custom_domain_id: domain.id, operation_type: operation_type,
                                domain_version: domain.version)
  end

  # Recovery budget spent. `verify`/`provision` end in `failed`, which is the
  # documented terminal state an operator can see and re-request from. A teardown
  # cannot be abandoned silently, so it keeps `removing` but carries an explicit
  # manual-intervention code and stops being re-armed.
  def abandon(domain, operation)
    code = ABANDON_CODES[operation.operation_type] || MANUAL_INTERVENTION_CODE
    return if domain.last_error_code == code

    if operation.operation_type == 'remove'
      domain.update!(last_error_code: code)
      # A known remote resource we can no longer reach needs an operator, and that
      # fact has to outlive the operation retention window.
      Lla::CustomDomains::TombstoneRecorder.record_abandoned_teardown!(operation)
    else
      Lla::CustomDomains::LifecycleService.new(portal: domain.portal).fail!(domain, code: code)
    end
    alert(domain, operation, code)
  end

  # The alerting hook: one structured event per newly abandoned domain, carrying
  # only internal IDs and stable codes.
  def alert(domain, operation, code)
    Lla::CustomDomains::Telemetry.emit('manual_intervention_required',
                                       account_id: domain.account_id, portal_id: domain.portal_id,
                                       domain_id: domain.id, operation_id: operation.id,
                                       operation_type: operation.operation_type,
                                       provider: domain.provider, state: domain.state, error_code: code)
  end

  # A teardown snapshot has no domain row left to reason about, so it is excluded
  # from `recover_terminal_operations`. It still names a *known* remote resource,
  # which means giving up on it silently would leak that resource with no evidence.
  def recover_orphan_teardowns(now)
    operations.where(state: %w[cancelled dead_lettered], custom_domain_id: nil, operation_type: 'remove')
              .where.not(provider_resource_id: nil)
              .order(id: :desc)
              .limit(BATCH_SIZE)
              .find_each do |operation|
      next if orphan_teardown_runnable?(operation)

      successor = Lla::CustomDomains::OperationService.enqueue_recovery!(operation, now: now)
      record_orphan_abandonment(operation) if successor.blank?
    end
  end

  def orphan_teardown_runnable?(operation)
    operations.runnable.exists?(custom_domain_id: nil, operation_type: 'remove',
                                hostname: operation.hostname,
                                provider_resource_id: operation.provider_resource_id)
  end

  def record_orphan_abandonment(operation)
    tombstone = Lla::CustomDomains::TombstoneRecorder.record_abandoned_teardown!(operation)
    return unless tombstone&.previously_new_record?

    Lla::CustomDomains::Telemetry.emit('manual_intervention_required',
                                       account_id: operation.account_id, operation_id: operation.id,
                                       operation_type: operation.operation_type,
                                       provider: operation.provider, state: operation.state,
                                       error_code: MANUAL_INTERVENTION_CODE)
  end

  # A challenge nobody answered inside its TTL is not a transient condition: the
  # domain is moved to the explicit, operator-visible `failed` state (from which an
  # administrator can retry) instead of waiting in `ownership_pending` with no proof
  # left to serve.
  def expire_challenges(now)
    Lla::CustomDomains::Domain.where(state: 'ownership_pending')
                              .where.not(challenge_expires_at: nil)
                              .where(challenge_expires_at: ...now)
                              .limit(BATCH_SIZE)
                              .find_each do |domain|
      Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
      Lla::CustomDomains::LifecycleService.new(portal: domain.portal).fail!(domain, code: CHALLENGE_EXPIRED_CODE)
    end
  end

  # A domain that has been `removing` for an hour with nothing runnable behind it.
  def rearm_stuck_removals(now)
    Lla::CustomDomains::Domain.pending_removal
                              .where(updated_at: ...(now - STUCK_REMOVAL_AFTER))
                              .where.not(last_error_code: MANUAL_INTERVENTION_CODE)
                              .limit(BATCH_SIZE)
                              .find_each do |domain|
      next if runnable_work?(domain, 'remove')

      rearm_removal(domain, now)
    end
  end

  def rearm_removal(domain, now)
    latest = operations.where(custom_domain_id: domain.id, operation_type: 'remove',
                              domain_version: domain.version).order(:id).last
    if latest.blank?
      Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'remove')
      return
    end

    successor = Lla::CustomDomains::OperationService.enqueue_recovery!(latest, now: now)
    abandon(domain, latest) if successor.blank?
  end

  # Cheap, bounded gauges so an operator can alert on stuck lifecycle state without
  # querying the tables by hand.
  def report_health(_now)
    {
      'health_failed_domains' => Lla::CustomDomains::Domain.where(state: 'failed').limit(BATCH_SIZE).count,
      'health_manual_intervention_domains' =>
        Lla::CustomDomains::Domain.where(last_error_code: MANUAL_INTERVENTION_CODE).limit(BATCH_SIZE).count,
      'health_outstanding_tombstones' => Lla::CustomDomains::Tombstone.outstanding.limit(BATCH_SIZE).count,
      'health_dead_lettered_operations' => operations.where(state: 'dead_lettered').limit(BATCH_SIZE).count
    }.each { |event, count| Lla::CustomDomains::Telemetry.emit(event, count: count) }
  end

  def purge_expired_operations(now)
    operations.where(state: operations::TERMINAL_STATES)
              .where(expires_at: ...(now - PURGE_GRACE))
              .where(successor_free_sql)
              .limit(BATCH_SIZE)
              .delete_all
  end

  # Never purge a predecessor that a live successor still points at.
  def successor_free_sql
    'NOT EXISTS (SELECT 1 FROM lla_custom_domain_operations successors ' \
      'WHERE successors.predecessor_id = lla_custom_domain_operations.id)'
  end
end
