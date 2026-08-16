# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Captain::QuotaReconciliationJob, type: :job do
  it 'reconciles pending current ledgers without stopping after one tenant failure' do
    ledgers = create_list(:account, 2, limits: { captain_responses: 1 }).map do |account|
      manager = Lla::Captain::QuotaManager.new(
        account: account,
        idempotency_key: "request-#{account.id}",
        owner_token: "worker-#{account.id}",
        feature: 'assistant',
        provider: 'openai',
        credential_source: 'system',
        reason: 'job_spec'
      )
      manager.reserve!
      account.lla_captain_quota_ledgers.sole
    end
    failing_service = instance_double(Lla::Captain::QuotaReconciliationService)
    successful_service = instance_double(Lla::Captain::QuotaReconciliationService, perform: true)
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: true)

    allow(described_class).to receive(:new).and_call_original
    allow(Lla::Captain::QuotaReconciliationService).to receive(:new).with(ledgers.first).and_return(failing_service)
    allow(Lla::Captain::QuotaReconciliationService).to receive(:new).with(ledgers.second).and_return(successful_service)
    allow(failing_service).to receive(:perform).and_raise(StandardError, 'provider body must not be logged')
    allow(ChatwootExceptionTracker).to receive(:new).with(instance_of(StandardError), account: ledgers.first.account).and_return(tracker)

    described_class.perform_now

    expect(successful_service).to have_received(:perform)
    expect(tracker).to have_received(:capture_exception)
  end
end
