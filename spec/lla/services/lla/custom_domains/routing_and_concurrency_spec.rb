# frozen_string_literal: true

require 'rails_helper'

# Two invariants that only show up at the edges: which hostnames are allowed to
# serve content, and what happens when several workers reach the same operation.
RSpec.describe Lla::CustomDomains::HostResolver do # rubocop:disable RSpec/SpecFilePathFormat
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:other_portal) { create(:portal, account: create(:account)) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
  let(:service) { Lla::CustomDomains::OperationService }
  let(:operations) { Lla::CustomDomains::Operation }
  let(:domain) { lifecycle.request!('docs.example.com') }

  def activate!
    domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
    lifecycle.activate!(domain, resource_id: nil, status: 'local')
    domain.reload
  end

  describe 'which lifecycle states serve traffic' do
    it 'serves an active proved domain and an active legacy import' do
      activate!
      expect(described_class.portal_for('docs.example.com')).to eq(portal)

      domain.update!(ownership_source: 'legacy_import', reverify_required: true,
                     ownership_verified_at: nil, activated_at: nil)
      expect(described_class.portal_for('docs.example.com')).to eq(portal)
    end

    it 'never serves requested, pending, provisioning, failed or removing domains' do
      expect(described_class.portal_for('docs.example.com')).to be_nil

      domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
      expect(described_class.portal_for('docs.example.com')).to be_nil

      lifecycle.fail!(domain, code: 'lla_custom_domain_ownership_unverified')
      expect(described_class.portal_for('docs.example.com')).to be_nil

      activate!
      lifecycle.release!
      expect(described_class.portal_for('docs.example.com')).to be_nil
    end

    it 'keeps serving a domain flagged for manual teardown intervention but blocks takeover' do
      activate!
      lifecycle.release!
      domain.reload.update!(last_error_code: Lla::CustomDomains::ReconciliationJob::MANUAL_INTERVENTION_CODE)

      expect(described_class.portal_for('docs.example.com')).to be_nil
      expect { Lla::CustomDomains::LifecycleService.new(portal: other_portal).request!('docs.example.com') }
        .to raise_error(Lla::CustomDomains::LifecycleService::Conflict)
    end
  end

  describe 'challenge exposure across states' do
    it 'exposes nothing once the domain leaves ownership_pending or reverification' do
      challenge = Lla::CustomDomains::OwnershipChallenge.issue!(domain)
      expect(Lla::CustomDomains::ChallengeResolver.resolve(host: 'docs.example.com', challenge_id: challenge.id))
        .to eq(challenge.body)

      %w[requested provisioning failed].each do |state|
        domain.update_columns(state: state, ownership_verified_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        expect(Lla::CustomDomains::ChallengeResolver.resolve(host: 'docs.example.com', challenge_id: challenge.id))
          .to be_nil
      end
    end
  end

  describe 'concurrent workers on one operation' do
    # Deterministic interleaving rather than OS threads: the claim is a single
    # conditional UPDATE, so racing it is equivalent to attempting it repeatedly
    # before any holder finalizes.
    it 'lets exactly one of many simultaneous workers claim, and only that one act' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      operation = operations.find_by!(custom_domain_id: domain.id, operation_type: 'verify')

      leases = Array.new(8) { service.claim!(operations.find(operation.id)) }.compact
      expect(leases.size).to eq(1)

      results = Array.new(3) { Lla::CustomDomains::OperationExecutor.new(leases.first).perform }
      expect(results.first).to be_present
      expect(domain.reload.state).to eq('provisioning')
      expect(operations.where(operation_type: 'provision').count).to eq(1)
      expect(results.drop(1)).to all(eq(:lease_lost))
    end

    it 'does not double provision when the same dispatch job runs many times' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      allow(Lla::CustomDomains::Providers::NullProvider).to receive(:provision)
        .and_return({ resource_id: nil, status: 'local' })
      operation = operations.find_by!(custom_domain_id: domain.id, operation_type: 'verify')
      Lla::CustomDomains::OperationDispatchJob.perform_now(operation.id)
      provision = operations.find_by!(operation_type: 'provision')

      5.times { Lla::CustomDomains::OperationDispatchJob.perform_now(provision.id) }

      expect(Lla::CustomDomains::Providers::NullProvider).to have_received(:provision).once
      expect(domain.reload.state).to eq('active')
      expect(provision.reload.state).to eq('succeeded')
    end

    it 'keeps the reconciler bounded and idempotent across repeated ticks' do
      activate!

      expect { 3.times { Lla::CustomDomains::ReconciliationJob.perform_now } }
        .not_to change(operations, :count)
    end
  end
end
