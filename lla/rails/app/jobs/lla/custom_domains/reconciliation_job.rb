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
  IN_FLIGHT_STATES = { 'verify' => 'ownership_pending', 'provision' => 'provisioning', 'remove' => 'removing' }.freeze
  ABANDON_CODES = {
    'verify' => 'lla_custom_domain_ownership_abandoned',
    'provision' => 'lla_custom_domain_provisioning_abandoned'
  }.freeze
  MANUAL_INTERVENTION_CODE = 'lla_custom_domain_teardown_manual_intervention'

  def perform(now: Time.current)
    expire_operations(now)
    redispatch_waiting(now)
    reclaim_stale_claims(now)
    recover_terminal_operations(now)
    expire_challenges(now)
    rearm_stuck_removals(now)
    purge_expired_operations(now)
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
    else
      Lla::CustomDomains::LifecycleService.new(portal: domain.portal).fail!(domain, code: code)
    end
  end

  def expire_challenges(now)
    Lla::CustomDomains::Domain.where(state: 'ownership_pending')
                              .where.not(challenge_expires_at: nil)
                              .where(challenge_expires_at: ...now)
                              .limit(BATCH_SIZE)
                              .find_each { |domain| Lla::CustomDomains::OwnershipChallenge.revoke!(domain) }
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
