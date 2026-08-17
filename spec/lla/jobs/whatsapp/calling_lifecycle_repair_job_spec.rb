# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::CallingLifecycleRepairJob do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                              validate_provider_config: false, sync_templates: false)
  end

  it 're-enqueues a non-converged lifecycle request without contacting the provider' do
    request_digest = Digest::SHA256.hexdigest('repair-request')
    channel.update!(provider_config: channel.provider_config.merge(
      'calling_requested_enabled' => true,
      'calling_enabled' => false,
      'calling_lifecycle_state' => 'failed',
      'calling_request_digest' => request_digest
    ))
    operation = Lla::Voice::CallOperation.create!(
      account: account,
      inbox: channel.inbox,
      action: 'enable_calling',
      state: 'failed',
      idempotency_digest: Digest::SHA256.hexdigest('repair-operation'),
      request_digest: request_digest,
      available_at: Time.current,
      attempts: 1
    )

    described_class.perform_now(account.id)

    expect(Whatsapp::CallingLifecycleJob).to have_been_enqueued.with(operation.id)
  end

  it 'skips an already converged inbox' do
    channel.update!(provider_config: channel.provider_config.merge(
      'calling_requested_enabled' => false,
      'calling_enabled' => false,
      'calling_lifecycle_state' => 'ready'
    ))

    described_class.perform_now(account.id)

    expect(Whatsapp::CallingLifecycleJob).not_to have_been_enqueued
  end
end
