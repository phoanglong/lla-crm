# frozen_string_literal: true

# Periodic safety net: re-dispatches operations whose backoff has elapsed, expires
# stale ownership challenges, and re-arms teardown for domains that are stuck in
# `removing`. Nothing here calls a provider directly.
class Lla::CustomDomains::ReconciliationJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 100
  STUCK_REMOVAL_AFTER = 1.hour

  def perform(now: Time.current)
    redispatch_pending(now)
    expire_challenges(now)
    rearm_stuck_removals(now)
    purge_expired_operations(now)
  end

  private

  def redispatch_pending(now)
    Lla::CustomDomains::Operation.dispatchable(now).limit(BATCH_SIZE).pluck(:id).each do |id|
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
    Lla::CustomDomains::Operation.where(state: Lla::CustomDomains::Operation::TERMINAL_STATES)
                                 .where(expires_at: ...now)
                                 .limit(BATCH_SIZE)
                                 .delete_all
  end
end
