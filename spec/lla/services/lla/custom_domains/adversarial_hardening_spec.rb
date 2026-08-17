# frozen_string_literal: true

require 'rails_helper'

# Regression cover for the failure modes found by the adversarial review of the
# cumulative G4a diff. Each block states the defect it pins, because the assertion
# on its own does not explain why it matters.
RSpec.describe 'Lla::CustomDomains hardening' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
  let(:service) { Lla::CustomDomains::OperationService }
  let(:operations) { Lla::CustomDomains::Operation }
  let(:domain) { lifecycle.request!('docs.example.com') }

  def terminalize!(operation, state: 'dead_lettered')
    operation.update_columns(state: state, completed_at: Time.current, # rubocop:disable Rails/SkipsModelValidations
                             claim_digest: nil, claimed_at: nil)
    operation
  end

  def activate!
    domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
    lifecycle.activate!(domain, resource_id: nil, status: 'local')
    domain.reload
  end

  # A terminal operation must not become a permanent tombstone for its own
  # idempotency key: the administrator would press the button and nothing at all
  # would happen, for the life of the domain.
  describe 'enqueue after a terminal attempt' do
    it 'creates a runnable successor when the previous attempt was dead lettered' do
      first = operations.find_by!(custom_domain_id: domain.id, operation_type: 'verify')
      terminalize!(first)

      second = service.enqueue!(domain: domain, operation_type: 'verify')

      expect(second.id).not_to eq(first.id)
      expect(second).to have_attributes(state: 'pending', recovery_attempt: 0, predecessor_id: nil,
                                        domain_version: domain.version)
    end

    it 'still returns the same row for a succeeded attempt, so no side effect runs twice' do
      first = operations.find_by!(custom_domain_id: domain.id, operation_type: 'verify')
      terminalize!(first, state: 'succeeded')

      expect(service.enqueue!(domain: domain, operation_type: 'verify').id).to eq(first.id)
    end

    it 'still collapses a double submission while the work is runnable' do
      first = operations.find_by!(custom_domain_id: domain.id, operation_type: 'verify')

      expect(service.enqueue!(domain: domain, operation_type: 'verify').id).to eq(first.id)
      expect(operations.where(custom_domain_id: domain.id, operation_type: 'verify').count).to eq(1)
    end

    it 'lets a teardown snapshot be re-armed after its own attempt died' do
      snapshot = service.enqueue_teardown!(account_id: account.id, hostname: 'docs.example.com',
                                           provider: 'cloudflare', provider_resource_id: 'cf-1',
                                           domain_version: 1)
      terminalize!(snapshot)

      successor = service.enqueue_teardown!(account_id: account.id, hostname: 'docs.example.com',
                                            provider: 'cloudflare', provider_resource_id: 'cf-1',
                                            domain_version: 1)

      expect(successor.id).not_to eq(snapshot.id)
      expect(successor.state).to eq('pending')
    end
  end

  # The installation's own hostnames already resolve to this application, so a proof
  # served over them would be this app answering its own probe.
  describe 'installation hostnames' do
    around do |example|
      with_modified_env('FRONTEND_URL' => 'https://app.lla-crm.com') { example.run }
    end

    it 'cannot be claimed as a custom domain' do
      expect { lifecycle.request!('app.lla-crm.com') }
        .to raise_error(Lla::CustomDomains::LifecycleService::InvalidRequest, /installation_host/)
      expect(Lla::CustomDomains::Domain.where(hostname: 'app.lla-crm.com')).not_to exist
    end

    it 'never serves an ownership challenge, even for a row that already exists' do
      challenge = Lla::CustomDomains::OwnershipChallenge.issue!(domain)
      domain.update_columns(hostname: 'app.lla-crm.com') # rubocop:disable Rails/SkipsModelValidations

      expect(Lla::CustomDomains::ChallengeResolver.resolve(host: 'app.lla-crm.com', challenge_id: challenge.id))
        .to be_nil
    end
  end

  # A result that comes back after the domain moved on is late, not authoritative.
  describe 'late results' do
    it 'does not push a released domain into failed when a provision attempt dies mid-flight' do
      domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
      operation = service.enqueue!(domain: domain, operation_type: 'provision')
      operation.update_columns(attempts: operation.max_attempts - 1) # rubocop:disable Rails/SkipsModelValidations
      lease = service.claim!(operations.find(operation.id))
      # The domain is released *while the provider call is in flight*, which is the
      # only window in which the executor has already passed its staleness check.
      allow(Lla::CustomDomains::Providers::NullProvider).to receive(:provision) do
        lifecycle.release!
        raise Lla::CustomDomains::ProviderErrors::Timeout
      end

      Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(domain.reload.state).to eq('removing')
      expect(operations.find(operation.id).state).to eq('dead_lettered')
    end

    it 'does not stamp an error code on a domain that has already been proved' do
      activate!
      domain.update!(ownership_source: 'legacy_import', reverify_required: true,
                     ownership_verified_at: nil, activated_at: nil)
      operation = service.enqueue!(domain: domain, operation_type: 'reverify')
      operation.update_columns(attempts: operation.max_attempts - 1) # rubocop:disable Rails/SkipsModelValidations
      lease = service.claim!(operations.find(operation.id))
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:unverified)

      lifecycle.promote_legacy!(domain.reload)
      Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(domain.reload).to have_attributes(last_error_code: nil, reverify_required: false)
    end

    it 'reports a removal that matched no row as stale rather than as a completed teardown' do
      activate!
      lifecycle.release!
      operation = operations.find_by!(custom_domain_id: domain.id, operation_type: 'remove')
      lease = service.claim!(operations.find(operation.id))
      domain.reload.update!(state: 'active', removal_requested_at: nil, ownership_verified_at: Time.current,
                            activated_at: Time.current, ownership_source: 'nonce_challenge',
                            reverify_required: false)

      Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(operations.find(operation.id).state).to eq('cancelled')
      expect(Lla::CustomDomains::Domain.where(id: domain.id)).to exist
      expect(Lla::CustomDomains::Tombstone.count).to eq(0)
    end
  end

  describe 'failed is an operator-visible state, not a dead end' do
    it 'lets an administrator start a genuinely new attempt on the same hostname' do
      lifecycle.fail!(domain, code: 'lla_custom_domain_ownership_unverified')
      previous_version = domain.reload.version

      lifecycle.retry_verification!(domain)

      expect(domain.reload).to have_attributes(state: 'ownership_pending', last_error_code: nil,
                                               version: previous_version + 1, challenge_rotations: 1)
      expect(operations.where(custom_domain_id: domain.id, operation_type: 'verify',
                              domain_version: previous_version + 1).count).to eq(1)
    end

    it 'bounds the retries with the challenge rotation budget' do
      domain.update!(challenge_rotations: Lla::CustomDomains::Domain::MAX_CHALLENGE_ROTATIONS)
      lifecycle.fail!(domain, code: 'lla_custom_domain_ownership_unverified')

      expect { lifecycle.retry_verification!(domain.reload) }
        .to raise_error(Lla::CustomDomains::LifecycleService::InvalidRequest, /retry_exhausted/)
      expect(domain.reload.state).to eq('failed')
    end

    it 'moves an unanswered challenge out of ownership_pending instead of leaving it silent' do
      domain.update_columns(challenge_expires_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations

      Lla::CustomDomains::ReconciliationJob.perform_now

      expect(domain.reload).to have_attributes(
        state: 'failed', last_error_code: Lla::CustomDomains::ReconciliationJob::CHALLENGE_EXPIRED_CODE
      )
    end
  end

  describe 'evidence that outlives the row' do
    it 'records a tombstone before a legacy import is repointed away' do
      activate!
      domain.update!(ownership_source: 'legacy_import', reverify_required: true, provider_status: 'active',
                     ownership_verified_at: nil, activated_at: nil)

      portal.update!(custom_domain: 'new.example.com')

      expect(Lla::CustomDomains::Tombstone.outstanding.find_by(hostname: 'docs.example.com'))
        .to have_attributes(reason: 'legacy_provider_resource_unknown', provider_status_hint: 'active')
      expect(domain.reload.hostname).to eq('new.example.com')
    end

    it 'never abandons a teardown snapshot without operator-visible evidence' do
      snapshot = service.enqueue_teardown!(account_id: account.id, hostname: 'docs.example.com',
                                           provider: 'cloudflare', provider_resource_id: 'cf-1',
                                           domain_version: 1)
      current = snapshot
      (Lla::CustomDomains::Operation::RECOVERY_LIMIT + 1).times do
        terminalize!(current)
        Lla::CustomDomains::ReconciliationJob.perform_now
        successor = operations.find_by(predecessor_id: current.id)
        break if successor.blank?

        current = successor
      end

      expect(Lla::CustomDomains::Tombstone.outstanding.find_by(hostname: 'docs.example.com'))
        .to have_attributes(reason: 'provider_teardown_abandoned', provider: 'cloudflare')
      expect(WebMock).not_to have_requested(:any, //)
    end
  end
end
