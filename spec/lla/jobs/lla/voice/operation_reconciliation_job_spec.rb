# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Voice::OperationReconciliationJob do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                              validate_provider_config: false, sync_templates: false)
  end

  let(:exception_tracker) { instance_double(ChatwootExceptionTracker, capture_exception: true) }

  before do
    allow(Redis::Alfred).to receive(:set).and_return(true)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(exception_tracker)
  end

  def create_operation(state:, action: 'enable_calling', claimed_at: nil, available_at: Time.current, attempts: 1)
    Lla::Voice::CallOperation.create!(
      account: account,
      inbox: channel.inbox,
      action: action,
      state: state,
      idempotency_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      request_digest: Digest::SHA256.hexdigest(SecureRandom.uuid),
      available_at: available_at,
      claimed_at: claimed_at,
      claim_digest: state == 'claimed' ? Digest::SHA256.hexdigest('worker') : nil,
      attempts: attempts
    )
  end

  it 'recovers stale claims and replays ready lifecycle failures' do
    stale = create_operation(state: 'claimed', claimed_at: 10.minutes.ago)
    ready = create_operation(state: 'failed', available_at: 1.minute.ago)
    delayed = create_operation(state: 'failed', available_at: 1.hour.from_now)
    exhausted = create_operation(state: 'failed', available_at: 1.minute.ago, attempts: 20)

    described_class.perform_now(account.id)

    expect(stale.reload).to have_attributes(state: 'failed', last_error_code: 'stale_claim', claim_digest: nil)
    expect(Whatsapp::CallingLifecycleJob).to have_been_enqueued.with(stale.id)
    expect(Whatsapp::CallingLifecycleJob).to have_been_enqueued.with(ready.id)
    expect(Whatsapp::CallingLifecycleJob).not_to have_been_enqueued.with(delayed.id)
    expect(Whatsapp::CallingLifecycleJob).not_to have_been_enqueued.with(exhausted.id)
    expect(exception_tracker).to have_received(:capture_exception).once
  end

  it 'does not mutate another account when scoped' do
    other = create_operation(state: 'claimed', claimed_at: 10.minutes.ago)
    scoped_account = create(:account)

    described_class.perform_now(scoped_account.id)

    expect(other.reload.state).to eq('claimed')
  end
end
