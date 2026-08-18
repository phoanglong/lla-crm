# frozen_string_literal: true

require 'rails_helper'

# LLA must never claim it deleted a remote object it cannot name. A legacy import
# that carried provider evidence but no resource ID leaves durable, operator-visible
# proof behind when it goes.
RSpec.describe Lla::CustomDomains::TombstoneRecorder do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
  let(:service) { Lla::CustomDomains::OperationService }
  let(:client) { Lla::CustomDomains::Providers::CloudflareClient }
  let(:domain) { lifecycle.request!('docs.example.com') }

  def make_legacy!(provider_status:)
    domain.update!(state: 'active', ownership_source: 'legacy_import', reverify_required: true,
                   ownership_verified_at: nil, activated_at: nil, provider_status: provider_status)
    Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
    domain.reload
  end

  def remove_now!
    lifecycle.release!
    operation = Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id, operation_type: 'remove')
    Lla::CustomDomains::OperationExecutor.new(service.claim!(operation)).perform
    operation.reload
  end

  describe '.adoption_required?' do
    it 'is false for a domain LLA provisioned itself' do
      domain.update!(provider: 'cloudflare', provider_resource_id: 'cf-1')

      expect(described_class.adoption_required?(domain)).to be(false)
    end

    it 'is false for a purely local legacy domain with no provider evidence' do
      expect(described_class.adoption_required?(make_legacy!(provider_status: nil))).to be(false)
    end

    it 'is true only for a legacy import that carried provider evidence but no id' do
      expect(described_class.adoption_required?(make_legacy!(provider_status: 'active'))).to be(true)
    end
  end

  describe 'removal' do
    it 'records a manual-adoption tombstone and performs zero egress' do
      make_legacy!(provider_status: 'active')
      allow(client).to receive(:delete_custom_hostname)

      operation = remove_now!

      tombstone = Lla::CustomDomains::Tombstone.find_by!(account_id: account.id, hostname: 'docs.example.com')
      expect(tombstone).to have_attributes(reason: 'legacy_provider_resource_unknown',
                                           state: 'manual_adoption_required', provider_status_hint: 'active')
      expect(operation.state).to eq('succeeded')
      expect(Lla::CustomDomains::Domain.where(id: domain.id)).not_to exist
      expect(client).not_to have_received(:delete_custom_hostname)
      expect(WebMock).not_to have_requested(:any, //)
    end

    it 'records nothing when there was never a remote object' do
      make_legacy!(provider_status: nil)

      remove_now!

      expect(Lla::CustomDomains::Tombstone.count).to eq(0)
    end

    it 'survives the domain row and stays outstanding until resolved' do
      make_legacy!(provider_status: 'active')
      remove_now!

      tombstone = Lla::CustomDomains::Tombstone.outstanding.find_by!(hostname: 'docs.example.com')
      tombstone.resolve!(reference: 'ops-1234')

      expect(Lla::CustomDomains::Tombstone.outstanding).to be_empty
      expect(tombstone.reload).to have_attributes(state: 'resolved', resolved_by_reference: 'ops-1234')
      expect(tombstone.resolved_at).to be_present
    end

    it 'is idempotent across a repeated removal of the same hostname' do
      make_legacy!(provider_status: 'active')
      remove_now!

      described_class.record!(account_id: account.id, hostname: 'docs.example.com',
                              reason: 'legacy_provider_resource_unknown')

      expect(Lla::CustomDomains::Tombstone.where(hostname: 'docs.example.com').count).to eq(1)
    end

    it 'records one when the portal itself is destroyed' do
      make_legacy!(provider_status: 'active')

      portal.destroy!

      expect(Lla::CustomDomains::Tombstone.where(hostname: 'docs.example.com').count).to eq(1)
    end
  end

  describe 'abandoned teardown of a known resource' do
    it 'records a tombstone once the recovery budget is spent' do
      domain.update!(provider: 'cloudflare', provider_resource_id: 'cf-resource-1')
      lifecycle.release!
      current = Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id, operation_type: 'remove')

      (Lla::CustomDomains::Operation::RECOVERY_LIMIT + 1).times do
        current.update_columns(state: 'dead_lettered', completed_at: Time.current, # rubocop:disable Rails/SkipsModelValidations
                               claim_digest: nil, claimed_at: nil)
        Lla::CustomDomains::ReconciliationJob.perform_now
        successor = Lla::CustomDomains::Operation.find_by(predecessor_id: current.id)
        break if successor.blank?

        current = successor
      end

      expect(Lla::CustomDomains::Tombstone.outstanding.find_by(hostname: 'docs.example.com'))
        .to have_attributes(reason: 'provider_teardown_abandoned', provider: 'cloudflare')
      expect(domain.reload.last_error_code)
        .to eq(Lla::CustomDomains::ReconciliationJob::MANUAL_INTERVENTION_CODE)
    end
  end
end
