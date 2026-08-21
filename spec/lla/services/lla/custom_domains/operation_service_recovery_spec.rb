# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::OperationService do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }

  describe 'dispatch is bound to the commit' do
    it 'leaves no job behind when the enclosing transaction rolls back' do
      clear_enqueued_jobs

      expect do
        ActiveRecord::Base.transaction do
          portal.update!(custom_domain: 'docs.example.com')
          raise ActiveRecord::Rollback
        end
      end.not_to change(Lla::CustomDomains::Domain, :count).from(0)

      expect(Lla::CustomDomains::Operation.count).to eq(0)
      expect(enqueued_jobs.select { |job| job['job_class'] == 'Lla::CustomDomains::OperationDispatchJob' }).to be_empty
    end

    it 'enqueues exactly one dispatch once the transaction commits' do
      clear_enqueued_jobs

      portal.update!(custom_domain: 'docs.example.com')

      dispatches = enqueued_jobs.select { |job| job['job_class'] == 'Lla::CustomDomains::OperationDispatchJob' }
      expect(dispatches.size).to eq(1)
      expect(Lla::CustomDomains::Operation.count).to eq(1)
    end
  end

  describe 'claim recovery' do
    let(:domain) { lifecycle.request!('docs.example.com') }
    let(:operation) { Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id, operation_type: 'verify') }

    it 'does not let a second worker steal a fresh claim' do
      expect(described_class.claim!(operation)).to be_present
      expect(described_class.claim!(Lla::CustomDomains::Operation.find(operation.id))).to be_nil
    end

    it 'reclaims a claim abandoned by a dead worker and mints a new lease token' do
      first = described_class.claim!(operation)
      expect(first).to be_present

      travel_to(Lla::CustomDomains::Operation::CLAIM_TIMEOUT.from_now + 1.minute) do
        reclaimed = described_class.claim!(Lla::CustomDomains::Operation.find(operation.id))

        expect(reclaimed).to be_present
        expect(reclaimed.token).not_to eq(first.token)
        expect(reclaimed.operation.claimed_with?(first.token)).to be(false)
        expect(reclaimed.operation.claimed_with?(reclaimed.token)).to be(true)
      end
    end

    it 'refuses to claim an operation that outlived its retention' do
      operation.update!(expires_at: 1.minute.ago)

      expect(described_class.claim!(operation)).to be_nil
    end

    it 'is re-dispatched and reclaimed by the reconciliation job' do
      described_class.claim!(operation)

      travel_to(Lla::CustomDomains::Operation::CLAIM_TIMEOUT.from_now + 1.minute) do
        clear_enqueued_jobs
        Lla::CustomDomains::ReconciliationJob.perform_now

        expect(enqueued_jobs.count { |job| job['job_class'] == 'Lla::CustomDomains::OperationDispatchJob' }).to eq(1)
      end
    end

    it 'cancels an expired operation instead of leaving it claimed forever' do
      described_class.claim!(operation)
      operation.update_columns(expires_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations

      Lla::CustomDomains::ReconciliationJob.perform_now

      expect(operation.reload).to have_attributes(state: 'cancelled', last_error_code: 'lla_custom_domain_operation_expired')
    end

    it 'purges a terminal operation only once it is past the audit grace period' do
      described_class.succeed!(described_class.claim!(operation))
      operation.update_columns(expires_at: 1.day.ago) # rubocop:disable Rails/SkipsModelValidations
      Lla::CustomDomains::ReconciliationJob.perform_now
      expect(Lla::CustomDomains::Operation.where(id: operation.id)).to exist

      operation.update_columns(expires_at: (Lla::CustomDomains::ReconciliationJob::PURGE_GRACE + 1.day).ago) # rubocop:disable Rails/SkipsModelValidations
      Lla::CustomDomains::ReconciliationJob.perform_now

      expect(Lla::CustomDomains::Operation.where(id: operation.id)).not_to exist
    end
  end

  describe 'disabled policy does not burn the retry budget' do
    let(:domain) { lifecycle.request!('docs.example.com') }
    let(:operation) { Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id, operation_type: 'verify') }

    it 'defers verification and keeps the domain waiting, not failed' do
      Lla::CustomDomains::Operation::MAX_ATTEMPTS.times do
        operation.update!(state: 'pending', available_at: 1.minute.ago, claim_digest: nil, claimed_at: nil)
        Lla::CustomDomains::OperationDispatchJob.perform_now(operation.id)
        operation.reload
      end

      expect(operation).to have_attributes(state: 'deferred', attempts: 0,
                                           last_error_code: 'lla_custom_domain_ownership_deferred')
      expect(operation.deferrals).to eq(Lla::CustomDomains::Operation::MAX_ATTEMPTS)
      expect(domain.reload.state).to eq('ownership_pending')
      expect(WebMock).not_to have_requested(:any, //)
    end

    it 'still counts a genuine verification failure against the budget' do
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:unverified)

      Lla::CustomDomains::OperationDispatchJob.perform_now(operation.id)

      expect(operation.reload).to have_attributes(state: 'pending', attempts: 1, deferrals: 0)
    end
  end

  describe 'scheduler' do
    it 'schedules the custom-domain reconciliation job' do
      schedule = YAML.load_file(Rails.root.join('config/schedule.yml'))

      expect(schedule['lla_custom_domain_reconciliation_job']).to include(
        'class' => 'Lla::CustomDomains::ReconciliationJob'
      )
      expect(schedule['lla_custom_domain_reconciliation_job']['cron']).to be_present
    end
  end
end
