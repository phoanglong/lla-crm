# frozen_string_literal: true

require 'rails_helper'

# The window this file exists for: a worker reads the domain, spends real time in a
# provider call, and only then writes. Anything may have happened to the row in
# between — an administrator releases or repoints it, the reconciler hands the work
# to a successor, another worker takes the lease.
#
# Every example below moves the row *inside* that window and asserts the same three
# things: the domain is exactly what the interleaving left, the worker wrote nothing,
# and its operation is not marked succeeded.
RSpec.describe 'Lla::CustomDomains fenced application' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
  let(:service) { Lla::CustomDomains::OperationService }
  let(:operations) { Lla::CustomDomains::Operation }
  let(:domain) { lifecycle.request!('docs.example.com') }

  def claim(operation_type)
    service.claim!(operations.find_by!(custom_domain_id: domain.id, operation_type: operation_type))
  end

  # One attempt left, so the next failure is the terminal one. Set before the claim:
  # the lease snapshots the row it claimed.
  def spend_retry_budget!
    operations.find_by!(custom_domain_id: domain.id, operation_type: 'verify')
              .update_columns(attempts: Lla::CustomDomains::Operation::MAX_ATTEMPTS - 1) # rubocop:disable Rails/SkipsModelValidations
  end

  def activate!
    domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
    lifecycle.activate!(domain, resource_id: nil, status: 'local')
    domain.reload
  end

  def make_legacy!
    activate!
    domain.update!(ownership_source: 'legacy_import', reverify_required: true,
                   ownership_verified_at: nil, activated_at: nil)
    domain.reload
  end

  describe 'a verify result that lands after the domain was released' do
    # The exact interleaving from the terminal-claim review.
    it 'leaves the release intact, writes nothing and does not report success' do
      lease = claim('verify')
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify) do
        lifecycle.release! # the administrator, while the proof fetch is in flight
        :verified
      end

      result = Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(result).to eq(:stale)
      expect(domain.reload).to have_attributes(state: 'removing', version: 2)
      expect(operations.find(lease.id).state).to eq('cancelled')
      expect(operations.where(operation_type: 'provision')).not_to exist
    end
  end

  describe 'a provision result that lands after the domain was repointed' do
    it 'never activates the new hostname with the old resource' do
      domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
      service.enqueue!(domain: domain, operation_type: 'provision')
      lease = claim('provision')
      allow(Lla::CustomDomains::Providers::NullProvider).to receive(:provision) do
        portal.update!(custom_domain: 'help.example.com') # repoint, mid-flight
        { resource_id: nil, status: 'local' }
      end

      result = Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(result).to eq(:stale)
      expect(domain.reload).to have_attributes(hostname: 'help.example.com', state: 'ownership_pending')
      expect(domain.activated_at).to be_nil
      expect(operations.find(lease.id).state).to eq('cancelled')
    end
  end

  describe 'a reverify result that lands after the legacy import was already proved' do
    it 'does not rewrite the proof timestamps of a domain someone else promoted' do
      make_legacy!
      lifecycle.request_reverify!(domain)
      lease = claim('reverify')
      promoted_at = 3.days.ago.change(usec: 0)
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify) do
        domain.reload.update!(ownership_source: 'nonce_challenge', reverify_required: false,
                              ownership_verified_at: promoted_at, activated_at: promoted_at)
        :verified
      end

      Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(domain.reload).to have_attributes(ownership_source: 'nonce_challenge',
                                               ownership_verified_at: promoted_at)
      expect(operations.find(lease.id).state).not_to eq('succeeded')
    end
  end

  describe 'a reconcile result that lands after the domain was released' do
    it 'does not write provider status onto a row that is being torn down' do
      activate!
      lease = service.claim!(service.enqueue!(domain: domain, operation_type: 'reconcile'))
      allow(Lla::CustomDomains::Providers::NullProvider).to receive(:check) do
        lifecycle.release!
        { status: 'active' }
      end

      result = Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(result).to eq(:stale)
      expect(domain.reload).to have_attributes(state: 'removing', provider_status: 'local')
      expect(operations.find(lease.id).state).to eq('cancelled')
    end
  end

  describe 'terminal failure metadata that lands after the domain moved' do
    it 'finalizes its own attempt but never pushes a released domain into failed' do
      spend_retry_budget!
      lease = claim('verify')
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify) do
        lifecycle.release!
        :unverified
      end

      Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(domain.reload).to have_attributes(state: 'removing', last_error_code: nil)
      expect(operations.find(lease.id).state).to eq('dead_lettered')
    end
  end

  describe 'a worker that lost its lease mid-flight' do
    it 'discards a verified proof instead of advancing the domain' do
      lease = claim('verify')
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify) do
        # The reconciler decides this claim is abandoned and hands it to a successor.
        operations.find(lease.id).update_columns(claimed_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
        service.claim!(operations.find(lease.id))
        :verified
      end

      result = Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(result).to eq(:lease_lost)
      expect(domain.reload.state).to eq('ownership_pending')
      expect(operations.find(lease.id).state).to eq('claimed')
      expect(operations.where(operation_type: 'provision')).not_to exist
    end

    it 'discards terminal failure metadata as well' do
      spend_retry_budget!
      lease = claim('verify')
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify) do
        operations.find(lease.id).update_columns(claimed_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
        service.claim!(operations.find(lease.id))
        :unverified
      end

      result = Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(result).to eq(:lease_lost)
      expect(domain.reload).to have_attributes(state: 'ownership_pending', last_error_code: nil)
      expect(operations.find(lease.id).state).to eq('claimed')
    end
  end

  describe 'challenge material' do
    it 'is never minted onto a row that was repointed since the read' do
      stale_view = Lla::CustomDomains::Domain.find(domain.id)
      portal.update!(custom_domain: 'help.example.com')

      expect { Lla::CustomDomains::OwnershipChallenge.rotate!(stale_view) }
        .to raise_error(Lla::CustomDomains::OwnershipChallenge::Stale)
      expect(domain.reload.challenge_rotations).to eq(0)
    end

    it 'is not expired by the reconciler when the administrator already retried' do
      lifecycle.fail!(domain, code: 'lla_custom_domain_ownership_unverified')
      lifecycle.retry_verification!(domain.reload)
      # The scan sees an expired challenge; the retry replaced it a moment later.
      domain.reload.update_columns(challenge_expires_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
      allow(Lla::CustomDomains::Domain).to receive(:lock).and_wrap_original do |original|
        domain.reload.update_columns(challenge_expires_at: 1.day.from_now) # rubocop:disable Rails/SkipsModelValidations
        original.call
      end

      Lla::CustomDomains::ReconciliationJob.perform_now

      expect(domain.reload.state).to eq('ownership_pending')
    end
  end

  describe 'the lock order' do
    # Proven by construction rather than by luck: every fenced path takes the
    # operation row first and the domain row second, so two workers racing on the
    # same domain queue behind each other instead of forming a cycle.
    it 'serializes two workers on one domain, letting exactly one result through' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      first = claim('verify')
      second = service.claim!(operations.find(first.id)) # only one claim can exist

      expect(second).to be_nil
      expect(Lla::CustomDomains::OperationExecutor.new(first).perform).to be_present
      expect(domain.reload.state).to eq('provisioning')
    end

    it 'takes the operation row before the domain row on every fenced path' do
      lease = claim('verify')
      order = []
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      allow(service).to receive(:hold!).and_wrap_original do |original, *args|
        order << :operation
        original.call(*args)
      end
      allow(Lla::CustomDomains::Domain).to receive(:lock).and_wrap_original do |original|
        order << :domain
        original.call
      end

      Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(order.first).to eq(:operation)
      expect(order.each_cons(2).none? { |first, second| first == :domain && second == :operation }).to be(true)
    end
  end
end
