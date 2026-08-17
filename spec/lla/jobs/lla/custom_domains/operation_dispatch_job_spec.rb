# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::OperationDispatchJob do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
  let(:domain) { lifecycle.request!('docs.example.com') }

  def verify_operation
    Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id, operation_type: 'verify')
  end

  describe 'ownership verification' do
    it 'advances to provisioning and enqueues provisioning when the proof is served' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)

      described_class.perform_now(verify_operation.id)

      expect(domain.reload.state).to eq('provisioning')
      expect(verify_operation.state).to eq('succeeded')
      expect(Lla::CustomDomains::Operation.where(operation_type: 'provision').count).to eq(1)
    end

    it 'retries and finally fails the domain when the proof never appears' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:unverified)
      operation = verify_operation

      operation.max_attempts.times do
        operation.update!(state: 'pending', available_at: 1.minute.ago)
        described_class.perform_now(operation.id)
        operation.reload
      end

      expect(operation.state).to eq('dead_lettered')
      expect(domain.reload).to have_attributes(state: 'failed', last_error_code: 'lla_custom_domain_ownership_unverified')
    end

    it 'defers instead of failing, with zero egress, when the capability and consent are absent' do
      operation = verify_operation

      described_class.perform_now(operation.id)

      expect(WebMock).not_to have_requested(:any, //)
      expect(operation.reload).to have_attributes(state: 'deferred', attempts: 0,
                                                  last_error_code: 'lla_custom_domain_ownership_deferred')
      expect(domain.reload.state).to eq('ownership_pending')
    end
  end

  describe 'staleness' do
    it 'cancels a result that arrives after the domain was repointed' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      operation = verify_operation
      lifecycle.request!('help.example.com')

      described_class.perform_now(operation.id)

      expect(operation.reload).to have_attributes(state: 'cancelled', last_error_code: 'lla_custom_domain_stale_operation')
      expect(domain.reload.state).to eq('ownership_pending')
    end

    it 'cancels an operation whose domain no longer exists' do
      operation = verify_operation
      domain.destroy!

      described_class.perform_now(operation.id)

      expect(operation.reload.state).to eq('cancelled')
    end
  end

  describe 'removal' do
    it 'tears the domain down once and stays idempotent on replay' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      described_class.perform_now(verify_operation.id)
      provision = Lla::CustomDomains::Operation.find_by!(operation_type: 'provision')
      described_class.perform_now(provision.id)
      expect(domain.reload.state).to eq('active')

      lifecycle.release!
      removal = Lla::CustomDomains::Operation.find_by!(operation_type: 'remove')
      described_class.perform_now(removal.id)

      expect(Lla::CustomDomains::Domain.where(id: domain.id)).to be_empty
      expect(removal.reload).to have_attributes(state: 'succeeded', custom_domain_id: nil)

      removal.update!(state: 'pending', available_at: 1.minute.ago, completed_at: nil)
      expect { described_class.perform_now(removal.id) }.not_to raise_error
      expect(removal.reload.state).to eq('succeeded')
    end
  end

  describe 'claiming' do
    it 'lets only the first worker execute a pending operation' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      operation = verify_operation

      described_class.perform_now(operation.id)
      expect(operation.reload.state).to eq('succeeded')

      expect { described_class.perform_now(operation.id) }.not_to(change { domain.reload.state })
    end
  end
end
