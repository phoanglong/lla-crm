# frozen_string_literal: true

# Durable, idempotent operation queue for custom-domain side effects.
#
# Enqueue is keyed by (account, domain, type, hostname, domain version) so a retry
# or a double click can never produce two provider calls. Dispatch happens in the
# record's `after_create_commit`, so a rolled back transaction leaves no job.
#
# ## Lease / fencing contract
#
# `claim!` mints a random lease token, stores only its SHA-256 digest in
# `claim_digest` and hands the raw token to the caller. From that moment the token
# is the *only* proof of ownership:
#
# * every finalization (`succeed!`, `defer!`, `fail!`, `cancel_stale!`) is a
#   conditional UPDATE with the predicate `state = 'claimed' AND claim_digest = ?`,
#   so a worker whose lease was reclaimed writes zero rows and gets `LeaseLost`;
# * `hold!` re-reads the row `FOR UPDATE` and compares the token in constant time,
#   so any domain mutation can be performed inside a transaction that is already
#   fenced — a late worker aborts *before* it touches the domain;
# * the reconciler's own transitions (`expire!`, reclaim) carry their own CAS
#   predicate instead of a token, and can never overwrite a terminal row.
class Lla::CustomDomains::OperationService
  class LeaseLost < StandardError
    def initialize(code = 'lla_custom_domain_lease_lost')
      super
    end
  end

  Lease = Struct.new(:operation, :token, keyword_init: true) do
    def id
      operation.id
    end
  end

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

  # Successor for a terminal operation that still has work to do. The digest folds
  # in the recovery generation, so the row is distinct from its predecessor but two
  # concurrent reconcilers still converge on exactly one successor.
  def self.enqueue_recovery!(operation, now: Time.current)
    generation = operation.recovery_attempt + 1
    return if generation > Lla::CustomDomains::Operation::RECOVERY_LIMIT

    digest = Digest::SHA256.hexdigest([operation.idempotency_digest, 'recovery', generation].join("\0"))
    Lla::CustomDomains::Operation.create_or_find_by!(idempotency_digest: digest) do |record|
      record.assign_attributes(
        account_id: operation.account_id, custom_domain_id: operation.custom_domain_id,
        operation_type: operation.operation_type, request_digest: operation.request_digest,
        hostname: operation.hostname, provider: operation.provider,
        provider_resource_id: operation.provider_resource_id, domain_version: operation.domain_version,
        predecessor_id: operation.id, recovery_attempt: generation, available_at: now
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

  # Atomically move a dispatchable (or abandoned) operation to `claimed` and return
  # the lease. Returns nil when another worker holds a fresh claim.
  def self.claim!(operation, now: Time.current)
    token = SecureRandom.hex(32)
    # Deliberately a single conditional UPDATE: the claim itself is the mutual
    # exclusion, so it must not go through a read-modify-write validation cycle.
    # rubocop:disable Rails/SkipsModelValidations
    claimed = claimable_scope(operation, now).update_all(
      state: 'claimed', claim_digest: digest_for(token), claimed_at: now, updated_at: now
    )
    # rubocop:enable Rails/SkipsModelValidations
    return if claimed.zero?

    Lease.new(operation: operation.reload, token: token)
  end

  # Row-locked ownership check. Anything mutating the domain runs inside the
  # transaction this opens, so a reclaimed worker aborts before the side effect.
  def self.hold!(lease)
    fresh = Lla::CustomDomains::Operation.lock.find_by(id: lease.id)
    raise LeaseLost if fresh.blank? || !fresh.claimed_with?(lease.token)

    fresh
  end

  def self.token_matches?(stored_digest, token)
    expected = stored_digest.to_s
    presented = digest_for(token)
    return false unless expected.bytesize == presented.bytesize

    ActiveSupport::SecurityUtils.secure_compare(expected, presented)
  end

  def self.digest_for(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.succeed!(lease, now: Time.current)
    finalize!(lease, state: 'succeeded', completed_at: now, last_error_code: nil)
  end

  def self.cancel_stale!(lease, code:, now: Time.current)
    finalize!(lease, state: 'cancelled', completed_at: now, last_error_code: code)
  end

  # A gate that is switched off is not a failure: the work waits without spending
  # any of the retry budget and without pushing the domain into `failed`.
  def self.defer!(lease, code:, now: Time.current)
    deferrals = [lease.operation.deferrals + 1, Lla::CustomDomains::Operation::MAX_DEFERRALS].min
    finalize!(lease, state: 'deferred', deferrals: deferrals, last_error_code: code,
                     available_at: now + Lla::CustomDomains::Operation::DEFERRAL_BACKOFF)
  end

  def self.fail!(lease, code:, now: Time.current)
    operation = lease.operation
    attempts = operation.attempts + 1
    if attempts >= operation.max_attempts
      return finalize!(lease, state: 'dead_lettered', attempts: attempts, completed_at: now, last_error_code: code)
    end

    finalize!(lease, state: 'pending', attempts: attempts, last_error_code: code,
                     available_at: operation.next_available_at(now))
  end

  # Fenced write: only the holder of the current lease may move the row.
  def self.finalize!(lease, **attributes)
    updates = attributes.reverse_merge(claim_digest: nil, claimed_at: nil).merge(updated_at: Time.current)
    # rubocop:disable Rails/SkipsModelValidations
    changed = Lla::CustomDomains::Operation
              .where(id: lease.id, state: 'claimed', claim_digest: digest_for(lease.token))
              .update_all(updates)
    # rubocop:enable Rails/SkipsModelValidations
    raise LeaseLost if changed.zero?

    lease.operation.reload
  end

  # Reconciler-owned transition. Its predicate is the expiry itself, so it can
  # never overwrite a row that already reached a terminal state.
  def self.expire!(operation, code:, now: Time.current)
    # rubocop:disable Rails/SkipsModelValidations
    changed = Lla::CustomDomains::Operation
              .where(id: operation.id, state: Lla::CustomDomains::Operation::WAITING_STATES + ['claimed'])
              .where(expires_at: ...now)
              .update_all(state: 'cancelled', completed_at: now, last_error_code: code,
                          claim_digest: nil, claimed_at: nil, updated_at: now)
    # rubocop:enable Rails/SkipsModelValidations
    changed.positive?
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
