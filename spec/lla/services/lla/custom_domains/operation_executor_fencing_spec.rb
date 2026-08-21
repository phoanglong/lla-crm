# frozen_string_literal: true

require 'rails_helper'

# Durability contract: what a worker may still do after it lost its lease, what a
# terminal-but-unfinished operation turns into, and what teardown does when there
# is no remote object to remove.
RSpec.describe Lla::CustomDomains::OperationExecutor do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
  let(:service) { Lla::CustomDomains::OperationService }
  let(:operations) { Lla::CustomDomains::Operation }
  let(:domain) { lifecycle.request!('docs.example.com') }
  let(:verify_operation) { operations.find_by!(custom_domain_id: domain.id, operation_type: 'verify') }

  # Simulates the dead-worker takeover: A's lease ages out and B reclaims it.
  def reclaim!(operation)
    travel(Lla::CustomDomains::Operation::CLAIM_TIMEOUT + 1.minute)
    service.claim!(operations.find(operation.id))
  end

  def advance_to_provisioning
    domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
    service.enqueue!(domain: domain, operation_type: 'provision')
  end

  def start_removal
    domain # the lifecycle row has to exist before it can be released
    lifecycle.release!
    operations.find_by!(custom_domain_id: domain.id, operation_type: 'remove')
  end

  # Marks an operation terminal the way a real cancellation/dead-letter would.
  def terminalize!(operation, state: 'cancelled')
    operation.update_columns(state: state, completed_at: Time.current, claim_digest: nil, # rubocop:disable Rails/SkipsModelValidations
                             claimed_at: nil, last_error_code: 'lla_custom_domain_provider_server_error')
    operation
  end

  # Walks the whole bounded recovery chain until the reconciler gives up.
  def exhaust_recovery(operation_type)
    current = operations.find_by!(custom_domain_id: domain.id, operation_type: operation_type)
    (Lla::CustomDomains::Operation::RECOVERY_LIMIT + 1).times do
      terminalize!(current)
      Lla::CustomDomains::ReconciliationJob.perform_now
      successor = operations.find_by(predecessor_id: current.id)
      break if successor.blank?

      current = successor
    end
    current
  end

  describe 'a reclaimed worker cannot mutate anything' do
    it 'stops before verifying and leaves the domain in ownership_pending' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      lease_a = service.claim!(verify_operation)
      lease_b = reclaim!(verify_operation)

      expect(described_class.new(lease_a).perform).to eq(:lease_lost)

      expect(domain.reload.state).to eq('ownership_pending')
      expect(verify_operation.reload).to have_attributes(state: 'claimed')
      expect(verify_operation.claimed_with?(lease_b.token)).to be(true)
      expect(verify_operation.claimed_with?(lease_a.token)).to be(false)
      expect(operations.where(operation_type: 'provision')).to be_empty
      expect(Lla::CustomDomains::OwnershipVerifier).not_to have_received(:verify)
    end

    it 'discards a verification result when the lease is lost mid-flight' do
      lease_a = service.claim!(verify_operation)
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify) do
        reclaim!(verify_operation)
        :verified
      end

      expect(described_class.new(lease_a).perform).to eq(:lease_lost)

      expect(domain.reload.state).to eq('ownership_pending')
      expect(operations.where(operation_type: 'provision')).to be_empty
    end

    it 'discards a provisioning result when the lease is lost mid-flight' do
      provision = advance_to_provisioning
      lease_a = service.claim!(provision)
      allow(Lla::CustomDomains::Providers::NullProvider).to receive(:provision) do
        reclaim!(provision)
        { resource_id: nil, status: 'local' }
      end

      expect(described_class.new(lease_a).perform).to eq(:lease_lost)

      expect(domain.reload).to have_attributes(state: 'provisioning', activated_at: nil)
    end

    it 'does not destroy the domain when the removal lease is lost mid-flight' do
      removal = start_removal
      lease_a = service.claim!(removal)
      allow(Lla::CustomDomains::Providers::NullProvider).to receive(:teardown) do
        reclaim!(removal)
        true
      end

      expect(described_class.new(lease_a).perform).to eq(:lease_lost)

      expect(domain.reload.state).to eq('removing')
      expect(Lla::CustomDomains::Domain.where(id: domain.id)).to exist
    end

    it 'cannot overwrite a cancellation written after its lease expired' do
      lease_a = service.claim!(verify_operation)
      verify_operation.update_columns(expires_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations

      Lla::CustomDomains::ReconciliationJob.perform_now
      expect(verify_operation.reload).to have_attributes(state: 'cancelled',
                                                         last_error_code: 'lla_custom_domain_operation_expired')

      expect { service.succeed!(lease_a) }.to raise_error(service::LeaseLost)
      expect(verify_operation.reload.state).to eq('cancelled')
    end
  end

  describe 'terminal removal recovery' do
    it 'creates exactly one runnable successor and keeps the predecessor' do
      removal = terminalize!(start_removal, state: 'dead_lettered')

      2.times { Lla::CustomDomains::ReconciliationJob.perform_now }

      successors = operations.where(predecessor_id: removal.id)
      expect(successors.count).to eq(1)
      expect(successors.first).to have_attributes(operation_type: 'remove', recovery_attempt: 1, state: 'pending')
      expect(removal.reload.state).to eq('dead_lettered')
      expect(operations.runnable.where(custom_domain_id: domain.id, operation_type: 'remove').count).to eq(1)
    end

    it 'does not duplicate work while a removal is still runnable' do
      start_removal

      Lla::CustomDomains::ReconciliationJob.perform_now

      expect(operations.where(custom_domain_id: domain.id, operation_type: 'remove').count).to eq(1)
    end

    it 'hands the domain to an operator once the bounded recovery budget is spent' do
      start_removal
      last = exhaust_recovery('remove')

      expect(last.recovery_attempt).to eq(Lla::CustomDomains::Operation::RECOVERY_LIMIT)
      expect(operations.where(custom_domain_id: domain.id, operation_type: 'remove').count)
        .to eq(Lla::CustomDomains::Operation::RECOVERY_LIMIT + 1)
      expect(domain.reload).to have_attributes(
        state: 'removing', last_error_code: Lla::CustomDomains::ReconciliationJob::MANUAL_INTERVENTION_CODE
      )
    end

    it 'stops re-arming a domain that already needs manual intervention' do
      start_removal
      exhaust_recovery('remove')

      expect { Lla::CustomDomains::ReconciliationJob.perform_now }.not_to change(operations, :count)
    end
  end

  describe 'terminal verification recovery' do
    it 'fails the domain explicitly once verification cannot be retried any more' do
      verify_operation
      exhaust_recovery('verify')

      expect(domain.reload).to have_attributes(
        state: 'failed', last_error_code: Lla::CustomDomains::ReconciliationJob::ABANDON_CODES['verify']
      )
    end

    it 'gives verification a bounded successor before giving up' do
      terminalize!(verify_operation)

      Lla::CustomDomains::ReconciliationJob.perform_now

      successor = operations.find_by(predecessor_id: verify_operation.id)
      expect(successor).to have_attributes(operation_type: 'verify', recovery_attempt: 1, state: 'pending')
      expect(domain.reload.state).to eq('ownership_pending')
    end
  end

  describe 'teardown without a remote resource' do
    let(:client) { Lla::CustomDomains::Providers::CloudflareClient }

    it 'completes local cleanup with zero egress even with every provider gate closed' do
      domain.update!(provider: 'cloudflare')
      removal = start_removal
      allow(client).to receive(:delete_custom_hostname)

      lease = service.claim!(removal)
      described_class.new(lease).perform

      expect(client).not_to have_received(:delete_custom_hostname)
      expect(WebMock).not_to have_requested(:any, //)
      expect(Lla::CustomDomains::Domain.where(id: domain.id)).not_to exist
      expect(removal.reload.state).to eq('succeeded')
    end

    it 'still defers when a real remote resource exists behind a closed gate' do
      domain.update!(provider: 'cloudflare', provider_resource_id: 'cf-resource-1')
      removal = start_removal
      allow(client).to receive(:delete_custom_hostname)

      lease = service.claim!(removal)
      described_class.new(lease).perform

      expect(client).not_to have_received(:delete_custom_hostname)
      expect(WebMock).not_to have_requested(:any, //)
      expect(removal.reload).to have_attributes(state: 'deferred', attempts: 0,
                                                last_error_code: 'lla_custom_domain_provider_not_configured')
      expect(Lla::CustomDomains::Domain.where(id: domain.id)).to exist
    end
  end
end
