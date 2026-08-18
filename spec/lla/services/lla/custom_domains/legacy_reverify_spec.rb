# frozen_string_literal: true

require 'rails_helper'

# Legacy imports keep serving while an administrator collects a real proof. Nothing
# here may fabricate that proof, break routing on failure, or reach the network while
# the capability and consent gates are shut.
RSpec.describe Lla::CustomDomains::LifecycleService do # rubocop:disable RSpec/SpecFilePathFormat
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:service) { Lla::CustomDomains::OperationService }
  let(:operations) { Lla::CustomDomains::Operation }
  let(:lifecycle) { described_class.new(portal: portal) }

  let(:domain) do
    record = lifecycle.request!('docs.example.com')
    record.update!(state: 'active', ownership_source: 'legacy_import', reverify_required: true,
                   ownership_verified_at: nil, activated_at: nil)
    Lla::CustomDomains::OwnershipChallenge.revoke!(record)
    operations.delete_all
    record.reload
  end

  def reverify_operation
    operations.find_by!(custom_domain_id: domain.id, operation_type: 'reverify')
  end

  def run_reverify
    Lla::CustomDomains::OperationExecutor.new(service.claim!(reverify_operation)).perform
  end

  describe '#request_reverify!' do
    it 'issues a challenge, enqueues one bounded operation and keeps routing intact' do
      lifecycle.request_reverify!(domain)

      expect(domain.reload).to have_attributes(state: 'active', reverify_required: true,
                                               ownership_source: 'legacy_import')
      expect(domain.challenge_active?).to be(true)
      expect(operations.where(operation_type: 'reverify').count).to eq(1)
      expect(Lla::CustomDomains::HostResolver.portal_for('docs.example.com')).to eq(portal)
      expect(WebMock).not_to have_requested(:any, //)
    end

    it 'is idempotent and does not rotate a live challenge' do
      lifecycle.request_reverify!(domain)
      digest = domain.reload.challenge_id_digest

      lifecycle.request_reverify!(domain.reload)

      expect(operations.where(operation_type: 'reverify').count).to eq(1)
      expect(domain.reload.challenge_id_digest).to eq(digest)
    end

    it 'refuses a domain that already carries a real proof' do
      domain.update!(ownership_source: 'nonce_challenge', reverify_required: false,
                     ownership_verified_at: Time.current, activated_at: Time.current)

      expect { lifecycle.request_reverify!(domain) }
        .to raise_error(described_class::InvalidRequest, 'lla_custom_domain_reverify_not_applicable')
    end
  end

  describe 'the challenge endpoint during reverification' do
    it 'serves the live proof for an active legacy domain and nothing otherwise' do
      challenge = Lla::CustomDomains::OwnershipChallenge.issue!(domain)

      expect(Lla::CustomDomains::ChallengeResolver.resolve(host: 'docs.example.com', challenge_id: challenge.id))
        .to eq(challenge.body)

      domain.update!(ownership_source: 'nonce_challenge', reverify_required: false,
                     ownership_verified_at: Time.current, activated_at: Time.current)
      expect(Lla::CustomDomains::ChallengeResolver.resolve(host: 'docs.example.com', challenge_id: challenge.id))
        .to be_nil
    end
  end

  describe 'running the reverification' do
    before { lifecycle.request_reverify!(domain) }

    it 'defers with zero egress while the capability is off' do
      run_reverify

      expect(reverify_operation).to have_attributes(state: 'deferred', attempts: 0,
                                                    last_error_code: 'lla_custom_domain_ownership_deferred')
      expect(domain.reload.reverify_required).to be(true)
      expect(WebMock).not_to have_requested(:any, //)
    end

    it 'promotes the domain only on a completed proof' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)

      run_reverify

      expect(domain.reload).to have_attributes(state: 'active', ownership_source: 'nonce_challenge',
                                               reverify_required: false, last_error_code: nil)
      expect(domain.ownership_verified_at).to be_present
      expect(domain.challenge_id_digest).to be_nil
      expect(reverify_operation.state).to eq('succeeded')
    end

    it 'keeps serving and records a stable code when the proof never appears' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:unverified)
      operation = reverify_operation

      operation.max_attempts.times do
        operation.update!(state: 'pending', available_at: 1.minute.ago, claim_digest: nil, claimed_at: nil)
        Lla::CustomDomains::OperationExecutor.new(service.claim!(operation)).perform
        operation.reload
      end

      expect(operation.state).to eq('dead_lettered')
      expect(domain.reload).to have_attributes(state: 'active', reverify_required: true,
                                               last_error_code: 'lla_custom_domain_reverify_unverified')
      expect(Lla::CustomDomains::HostResolver.portal_for('docs.example.com')).to eq(portal)
    end

    it 'is not turned into an automatic successor by the reconciler' do
      operation = reverify_operation
      operation.update_columns(state: 'cancelled', completed_at: Time.current, # rubocop:disable Rails/SkipsModelValidations
                               claim_digest: nil, claimed_at: nil)

      Lla::CustomDomains::ReconciliationJob.perform_now

      expect(operations.where(predecessor_id: operation.id)).to be_empty
      expect(domain.reload).to have_attributes(state: 'active', reverify_required: true)
    end

    it 'stops a stale worker from promoting the domain after its lease is reclaimed' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      lease_a = service.claim!(reverify_operation)
      travel(Lla::CustomDomains::Operation::CLAIM_TIMEOUT + 1.minute)
      service.claim!(operations.find(lease_a.id))

      expect(Lla::CustomDomains::OperationExecutor.new(lease_a).perform).to eq(:lease_lost)
      expect(domain.reload).to have_attributes(ownership_source: 'legacy_import', reverify_required: true)
    end
  end
end
