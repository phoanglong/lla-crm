# frozen_string_literal: true

# Durable, idempotent operation queue for custom-domain side effects.
#
# Enqueue is keyed by (account, domain, type, hostname, domain version) so a retry
# or a double click can never produce two provider calls. Dispatch happens in the
# record's `after_create_commit`, so a rolled back transaction leaves no job.
# Claiming is a single atomic UPDATE that also reclaims claims abandoned by a dead
# worker. Failures back off and are dead lettered once the budget is spent, while
# a disabled capability defers without spending any of it.
class Lla::CustomDomains::OperationService
  def self.enqueue!(domain:, operation_type:, available_at: nil)
    raise ArgumentError, "unknown operation type: #{operation_type}" unless Lla::CustomDomains::Operation::TYPES.include?(operation_type.to_s)

    digest = idempotency_digest(domain, operation_type)
    Lla::CustomDomains::Operation.create_or_find_by!(idempotency_digest: digest) do |record|
      record.assign_attributes(
        account_id: domain.account_id, custom_domain_id: domain.id, operation_type: operation_type.to_s,
        request_digest: request_digest(domain, operation_type), hostname: domain.hostname,
        provider: domain.provider, provider_resource_id: domain.provider_resource_id,
        domain_version: domain.version, available_at: available_at || Time.current
      )
    end
  end

  # Snapshot enqueue used when the domain row itself is about to disappear
  # (portal or domain destroyed): the remote resource still has to be torn down.
  def self.enqueue_teardown!(account_id:, hostname:, provider:, provider_resource_id:, domain_version:)
    return if provider.to_s == 'none' || provider_resource_id.blank?

    digest = Digest::SHA256.hexdigest([account_id, hostname, 'remove', provider, provider_resource_id].join("\0"))
    Lla::CustomDomains::Operation.create_or_find_by!(idempotency_digest: digest) do |record|
      record.assign_attributes(
        account_id: account_id, custom_domain_id: nil, operation_type: 'remove',
        request_digest: digest, hostname: hostname, provider: provider,
        provider_resource_id: provider_resource_id, domain_version: domain_version,
        available_at: Time.current
      )
    end
  end

  # Atomically move a dispatchable (or abandoned) operation to `claimed`. Returns
  # nil when another worker holds a fresh claim or the operation is not runnable.
  def self.claim!(operation, now: Time.current)
    token = SecureRandom.hex(32)
    # Deliberately a single conditional UPDATE: the claim itself is the mutual
    # exclusion, so it must not go through a read-modify-write validation cycle.
    # rubocop:disable Rails/SkipsModelValidations
    claimed = claimable_scope(operation, now).update_all(
      state: 'claimed', claim_digest: token, claimed_at: now, updated_at: now
    )
    # rubocop:enable Rails/SkipsModelValidations
    return if claimed.zero?

    operation.reload
  end

  def self.claimable_scope(operation, now)
    fresh_claim_cutoff = now - Lla::CustomDomains::Operation::CLAIM_TIMEOUT
    Lla::CustomDomains::Operation
      .where(id: operation.id)
      .where(expires_at: now..)
      .where(
        '(state IN (:waiting) AND available_at <= :now) OR (state = :claimed AND claimed_at < :cutoff)',
        waiting: Lla::CustomDomains::Operation::WAITING_STATES, now: now, claimed: 'claimed', cutoff: fresh_claim_cutoff
      )
  end
  private_class_method :claimable_scope

  def self.succeed!(operation, now: Time.current)
    operation.update!(state: 'succeeded', completed_at: now, last_error_code: nil, claim_digest: nil, claimed_at: nil)
  end

  def self.cancel!(operation, code:, now: Time.current)
    operation.update!(state: 'cancelled', completed_at: now, last_error_code: code, claim_digest: nil, claimed_at: nil)
  end

  # A gate that is switched off is not a failure: the work waits without spending
  # any of the retry budget and without pushing the domain into `failed`.
  def self.defer!(operation, code:, now: Time.current)
    deferrals = [operation.deferrals + 1, Lla::CustomDomains::Operation::MAX_DEFERRALS].min
    operation.update!(state: 'deferred', deferrals: deferrals, last_error_code: code,
                      claim_digest: nil, claimed_at: nil,
                      available_at: now + Lla::CustomDomains::Operation::DEFERRAL_BACKOFF)
    operation
  end

  def self.fail!(operation, code:, now: Time.current)
    attempts = operation.attempts + 1
    if attempts >= operation.max_attempts
      operation.update!(state: 'dead_lettered', attempts: attempts, completed_at: now,
                        last_error_code: code, claim_digest: nil, claimed_at: nil)
      return operation
    end

    operation.update!(state: 'pending', attempts: attempts, last_error_code: code, claim_digest: nil,
                      claimed_at: nil, available_at: operation.next_available_at(now))
    operation
  end

  def self.idempotency_digest(domain, operation_type)
    Digest::SHA256.hexdigest(
      [domain.account_id, domain.id, operation_type, domain.hostname, domain.version].join("\0")
    )
  end

  def self.request_digest(domain, operation_type)
    Digest::SHA256.hexdigest(
      [domain.portal_id, domain.provider, domain.state, operation_type, domain.hostname].join("\0")
    )
  end
end
