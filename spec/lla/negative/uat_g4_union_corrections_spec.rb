# frozen_string_literal: true

require 'rails_helper'

# Negatives for the defects the independent UAT review found in the two G4
# candidates. Each example fails on the submitted G4a/G4b trees and passes on this
# branch; that is the whole point of the file.
RSpec.describe 'Wave G4 union corrections' do # rubocop:disable RSpec/DescribeClass
  describe 'releasing a custom domain when the conditional write loses' do
    let(:account) { create(:account) }
    let(:portal) { create(:portal, account: account, custom_domain: 'docs.example.com') }

    before { portal }

    # The defect: `release!` returned silently when its fenced update matched no row.
    # The administrator's save that cleared `portals.custom_domain` still committed,
    # so the column ended up NULL while the lifecycle row stayed active, kept
    # resolving the hostname, and no `remove` operation was ever enqueued. Nothing
    # reconciles that state — `rearm_stuck_removals` only looks at `removing` rows.
    it 'refuses to clear the portal column when the lifecycle row cannot be moved' do
      domain = Lla::CustomDomains::Domain.find_by!(portal_id: portal.id)
      allow_any_instance_of(Lla::CustomDomains::Domain).to receive(:fenced_update).and_return(false) # rubocop:disable RSpec/AnyInstance

      expect { portal.update!(custom_domain: nil) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(portal.reload.custom_domain).to eq('docs.example.com')
      expect(domain.reload.state).not_to eq('removing')
      expect(Lla::CustomDomains::Operation.where(custom_domain_id: domain.id, operation_type: 'remove')).to be_empty
    end

    it 'surfaces the conflict with a stable code rather than a silent no-op' do
      allow_any_instance_of(Lla::CustomDomains::Domain).to receive(:fenced_update).and_return(false) # rubocop:disable RSpec/AnyInstance

      expect { Lla::CustomDomains::LifecycleService.new(portal: portal).release! }
        .to raise_error(Lla::CustomDomains::LifecycleService::InvalidRequest) { |e|
              expect(e.code).to eq('lla_custom_domain_conflict')
            }
    end

    # Losing the race once is ordinary: a worker finished the provisioning the
    # administrator is cancelling. The retry re-reads and succeeds, so an honest
    # race does not turn into an error the operator has to interpret.
    it 'retries a single lost race and completes the release' do
      domain = Lla::CustomDomains::Domain.find_by!(portal_id: portal.id)
      calls = 0
      allow_any_instance_of(Lla::CustomDomains::Domain).to receive(:fenced_update).and_wrap_original do |original, *args, **kwargs| # rubocop:disable RSpec/AnyInstance
        calls += 1
        calls == 1 ? false : original.call(*args, **kwargs)
      end

      portal.update!(custom_domain: nil)

      expect(portal.reload.custom_domain).to be_nil
      expect(domain.reload.state).to eq('removing')
      expect(Lla::CustomDomains::Operation.where(custom_domain_id: domain.id, operation_type: 'remove')).to be_present
    end
  end

  describe 'deleting a tenant that still owes a provider something' do
    let(:account) { create(:account) }
    let(:portal) { create(:portal, account: account) }

    def abandoned_evidence!
      Lla::CustomDomains::Tombstone.create!(
        account_id: account.id, portal_id: portal.id, source_portal_id: portal.id,
        hostname: 'docs.example.com', reason: 'provider_teardown_abandoned',
        provider: 'cloudflare', provider_resource_id: 'cf-resource-a',
        provider_resource_digest: Lla::CustomDomains::Tombstone.resource_digest_for('cf-resource-a')
      )
    end

    # G4a asserted that deleting an account silently destroys this evidence. That is
    # a remote object nobody can find afterwards, so the application path now refuses.
    it 'refuses the delete and keeps the evidence' do
      evidence = abandoned_evidence!

      expect { account.destroy! }
        .to raise_error(Lla::CustomDomains::AccountDeletionSweep::ObligationsOutstanding)

      expect(Account.exists?(id: account.id)).to be(true)
      expect(evidence.reload.state).to eq('manual_adoption_required')
    end

    it 'exports the obligation with the identifier that makes it actionable' do
      abandoned_evidence!
      exported = nil
      allow(Rails.logger).to receive(:warn) do |line|
        exported ||= line if line.to_s.include?('lla_custom_domain_account_deletion_export')
      end

      expect { account.destroy! }.to raise_error(Lla::CustomDomains::AccountDeletionSweep::ObligationsOutstanding)

      payload = JSON.parse(exported.to_s)
      expect(payload['account_id']).to eq(account.id)
      expect(payload['obligations'].first).to include('kind' => 'tombstone', 'provider_resource_id' => 'cf-resource-a')
    end

    it 'still exports, but proceeds, when an operator sets the explicit override' do
      abandoned_evidence!
      exported = false
      allow(Rails.logger).to receive(:warn) do |line|
        exported ||= line.to_s.include?('lla_custom_domain_account_deletion_export')
      end

      with_modified_env(Lla::CustomDomains::AccountDeletionSweep::OVERRIDE_FLAG => 'true') do
        account.destroy!
      end

      expect(exported).to be(true)
      expect(Account.exists?(id: account.id)).to be(false)
    end

    it 'does not interfere with a tenant that owes nothing' do
      portal

      expect { account.destroy! }.not_to raise_error
      expect(Account.exists?(id: account.id)).to be(false)
    end
  end
end
