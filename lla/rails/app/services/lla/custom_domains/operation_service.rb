# frozen_string_literal: true

# Durable, idempotent operation queue for custom-domain side effects.
#
# Enqueue is keyed by (account, domain, type, hostname, domain version) so a retry
# or a double click can never produce two provider calls. Claiming is a single
# atomic UPDATE, so two workers cannot run the same operation. Failures back off
# and are dead lettered once the budget is spent instead of looping forever.
class Lla::CustomDomains::OperationService
  def self.enqueue!(domain:, operation_type:, available_at: nil)
    raise ArgumentError, "unknown operation type: #{operation_type}" unless Lla::CustomDomains::Operation::TYPES.include?(operation_type.to_s)

    digest = idempotency_digest(domain, operation_type)
    operation = Lla::CustomDomains::Operation.create_or_find_by!(idempotency_digest: digest) do |record|
      record.assign_attributes(
        account_id: domain.account_id, custom_domain_id: domain.id, operation_type: operation_type.to_s,
        request_digest: request_digest(domain, operation_type), hostname: domain.hostname,
        provider: domain.provider, provider_resource_id: domain.provider_resource_id,
        domain_version: domain.version, available_at: available_at || Time.current
      )
    end

    Lla::CustomDomains::OperationDispatchJob.perform_later(operation.id) if operation.state == 'pending'
    operation
  end

  # Snapshot enqueue used when the domain row itself is about to disappear
  # (portal or domain destroyed): the remote resource still has to be torn down.
  def self.enqueue_teardown!(account_id:, hostname:, provider:, provider_resource_id:, domain_version:)
    return if provider.to_s == 'none' || provider_resource_id.blank?

    digest = Digest::SHA256.hexdigest([account_id, hostname, 'remove', provider, provider_resource_id].join("\0"))
    operation = Lla::CustomDomains::Operation.create_or_find_by!(idempotency_digest: digest) do |record|
      record.account_id = account_id
      record.custom_domain_id = nil
      record.operation_type = 'remove'
      record.request_digest = digest
      record.hostname = hostname
      record.provider = provider
      record.provider_resource_id = provider_resource_id
      record.domain_version = domain_version
      record.available_at = Time.current
    end

    Lla::CustomDomains::OperationDispatchJob.perform_later(operation.id) if operation.state == 'pending'
    operation
  end

  # Atomically move a dispatchable operation to `claimed`. Returns nil when
  # another worker won the race or the operation is no longer dispatchable.
  def self.claim!(operation, now: Time.current)
    token = SecureRandom.hex(32)
    # Deliberately a single conditional UPDATE: the claim itself is the mutual
    # exclusion, so it must not go through a read-modify-write validation cycle.
    # rubocop:disable Rails/SkipsModelValidations
    claimed = Lla::CustomDomains::Operation.where(id: operation.id, state: 'pending')
                                           .where(available_at: ..now)
                                           .update_all(state: 'claimed', claim_digest: token, claimed_at: now, updated_at: now)
    # rubocop:enable Rails/SkipsModelValidations
    return if claimed.zero?

    operation.reload
  end

  def self.succeed!(operation, now: Time.current)
    operation.update!(state: 'succeeded', completed_at: now, last_error_code: nil, claim_digest: nil)
  end

  def self.cancel!(operation, code:, now: Time.current)
    operation.update!(state: 'cancelled', completed_at: now, last_error_code: code, claim_digest: nil)
  end

  def self.fail!(operation, code:, now: Time.current)
    attempts = operation.attempts + 1
    if attempts >= operation.max_attempts
      operation.update!(state: 'dead_lettered', attempts: attempts, completed_at: now,
                        last_error_code: code, claim_digest: nil)
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
