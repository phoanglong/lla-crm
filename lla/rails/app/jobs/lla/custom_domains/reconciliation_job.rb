# frozen_string_literal: true

# Periodic safety net for the custom-domain operation queue.
#
# It re-dispatches waiting work whose backoff or deferral window has elapsed,
# reclaims claims abandoned by a dead worker, cancels operations that outlived
# their retention, expires stale ownership challenges and re-arms teardown for
# domains stuck in `removing`. Reclaiming is done by the same atomic CAS as the
# normal claim, so a worker that is still alive can never be robbed of its work.
class Lla::CustomDomains::ReconciliationJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100
  STUCK_REMOVAL_AFTER = 1.hour
  # Terminal rows are kept for a while past retention so the cancellation that
  # ended them stays auditable instead of vanishing in the same tick.
  PURGE_GRACE = 7.days

  def perform(now: Time.current)
    expire_operations(now)
    redispatch_waiting(now)
    reclaim_stale_claims(now)
    expire_challenges(now)
    rearm_stuck_removals(now)
    purge_expired_operations(now)
  end

  private

  def operations
    Lla::CustomDomains::Operation
  end

  # Past its retention window: stop touching the provider, record it and move on.
  def expire_operations(now)
    operations.where(state: operations::WAITING_STATES + ['claimed'])
              .where(expires_at: ...now)
              .limit(BATCH_SIZE)
              .find_each do |operation|
      Lla::CustomDomains::OperationService.cancel!(operation, code: 'lla_custom_domain_operation_expired', now: now)
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

  def expire_challenges(now)
    Lla::CustomDomains::Domain.where(state: 'ownership_pending')
                              .where.not(challenge_expires_at: nil)
                              .where(challenge_expires_at: ...now)
                              .limit(BATCH_SIZE)
                              .find_each { |domain| Lla::CustomDomains::OwnershipChallenge.revoke!(domain) }
  end

  def rearm_stuck_removals(now)
    Lla::CustomDomains::Domain.pending_removal
                              .where(updated_at: ...(now - STUCK_REMOVAL_AFTER))
                              .limit(BATCH_SIZE)
                              .find_each do |domain|
      Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'remove')
    end
  end

  def purge_expired_operations(now)
    operations.where(state: operations::TERMINAL_STATES)
              .where(expires_at: ...(now - PURGE_GRACE))
              .limit(BATCH_SIZE)
              .delete_all
  end
end
