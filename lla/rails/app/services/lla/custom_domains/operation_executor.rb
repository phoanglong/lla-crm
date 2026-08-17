# frozen_string_literal: true

# Runs one claimed custom-domain operation.
#
# Every branch is guarded by a stale check: if the domain was repointed, released
# or destroyed since the operation was enqueued, the result is discarded instead of
# activating a hostname the tenant no longer owns.
class Lla::CustomDomains::OperationExecutor
  def initialize(operation)
    @operation = operation
  end

  def perform
    return teardown_snapshot if operation.custom_domain_id.blank?

    domain = Lla::CustomDomains::Domain.find_by(id: operation.custom_domain_id)
    return stale!(domain) if operation.stale_for?(domain)

    case operation.operation_type
    when 'verify' then run_verify(domain)
    when 'provision' then run_provision(domain)
    when 'remove' then run_remove(domain)
    when 'reconcile' then run_reconcile(domain)
    end
  end

  private

  attr_reader :operation

  def lifecycle(domain)
    Lla::CustomDomains::LifecycleService.new(portal: domain.portal)
  end

  def stale!(domain)
    # A domain already in `removing` is not stale for a remove operation: tearing
    # it down is exactly that operation's job.
    return run_remove(domain) if domain&.state == 'removing' && operation.operation_type == 'remove' && domain.hostname == operation.hostname

    Lla::CustomDomains::OperationService.cancel!(operation, code: 'lla_custom_domain_stale_operation')
  end

  def run_verify(domain)
    return Lla::CustomDomains::OperationService.cancel!(operation, code: 'lla_custom_domain_not_pending') unless
      domain.state == 'ownership_pending'

    if Lla::CustomDomains::OwnershipVerifier.verify(domain)
      lifecycle(domain).mark_ownership_verified!(domain)
      Lla::CustomDomains::OperationService.succeed!(operation)
    else
      retry_or_fail(domain, 'lla_custom_domain_ownership_unverified')
    end
  end

  def run_provision(domain)
    return Lla::CustomDomains::OperationService.cancel!(operation, code: 'lla_custom_domain_not_provisioning') unless
      domain.state == 'provisioning'

    result = domain.provider_adapter.provision(domain)
    lifecycle(domain).activate!(domain, resource_id: result[:resource_id], status: result[:status])
    Lla::CustomDomains::OperationService.succeed!(operation)
  rescue Lla::CustomDomains::ProviderErrors::Error => e
    retry_or_fail(domain, e.code)
  end

  def run_remove(domain)
    return Lla::CustomDomains::OperationService.cancel!(operation, code: 'lla_custom_domain_not_removing') unless
      domain.state == 'removing'

    domain.provider_adapter.teardown(domain.hostname, domain.provider_resource_id)
    domain.destroy!
    Lla::CustomDomains::OperationService.succeed!(operation)
  rescue Lla::CustomDomains::ProviderErrors::Error => e
    Lla::CustomDomains::OperationService.fail!(operation, code: e.code)
  end

  def run_reconcile(domain)
    result = domain.provider_adapter.check(domain)
    domain.update!(provider_status: result[:status], provider_synced_at: Time.current)
    Lla::CustomDomains::OperationService.succeed!(operation)
  rescue Lla::CustomDomains::ProviderErrors::Error => e
    Lla::CustomDomains::OperationService.fail!(operation, code: e.code)
  end

  # The domain row is already gone; only the remote resource still has to be
  # released. Repeated runs are safe because provider teardown is idempotent.
  def teardown_snapshot
    unless operation.operation_type == 'remove'
      return Lla::CustomDomains::OperationService.cancel!(operation, code: 'lla_custom_domain_stale_operation')
    end

    Lla::CustomDomains::ProviderRegistry.for(operation.provider)
                                        .teardown(operation.hostname, operation.provider_resource_id)
    Lla::CustomDomains::OperationService.succeed!(operation)
  rescue Lla::CustomDomains::ProviderErrors::Error => e
    Lla::CustomDomains::OperationService.fail!(operation, code: e.code)
  end

  def retry_or_fail(domain, code)
    Lla::CustomDomains::OperationService.fail!(operation, code: code)
    return unless operation.reload.state == 'dead_lettered'

    lifecycle(domain).fail!(domain, code: code)
  end
end
