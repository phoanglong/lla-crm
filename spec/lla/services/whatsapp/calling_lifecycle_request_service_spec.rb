# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::CallingLifecycleRequestService do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                              validate_provider_config: false, sync_templates: false)
  end

  before { account.enable_features!('channel_voice') }

  def request(enabled:, key: 'whatsapp-calling-request-1', user: admin)
    described_class.new(inbox: channel.inbox, user: user, enabled: enabled, idempotency_key: key).perform
  end

  it 'records desired state and enqueues an owned lifecycle operation' do
    expect(request(enabled: true)).to eq(calling_requested_enabled: true, calling_lifecycle_state: 'pending')

    operation = Lla::Voice::CallOperation.last
    expect(operation).to have_attributes(action: 'enable_calling', state: 'pending', account_id: account.id,
                                         inbox_id: channel.inbox.id)
    expect(operation.idempotency_digest).not_to include('whatsapp-calling-request-1')
    expect(Whatsapp::CallingLifecycleJob).to have_been_enqueued.with(operation.id)
    expect(channel.reload.provider_config).to include('calling_requested_enabled' => true,
                                                      'calling_lifecycle_state' => 'pending')
  end

  it 'rejects reuse of an idempotency key for the opposite desired state' do
    request(enabled: true)

    expect { request(enabled: false) }
      .to raise_error(described_class::IdempotencyConflict, 'Idempotency-Key was used for another request')
  end

  it 'gates local calling immediately when disable is requested' do
    channel.update!(provider_config: channel.provider_config.merge('calling_enabled' => true))

    request(enabled: false, key: 'whatsapp-calling-disable-1')

    expect(channel.reload.provider_config).to include('calling_requested_enabled' => false,
                                                      'calling_enabled' => false,
                                                      'calling_lifecycle_state' => 'pending')
  end

  it 'rejects an agent even when they are an inbox member' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: channel.inbox, user: agent)

    expect { request(enabled: true, user: agent) }.to raise_error(Pundit::NotAuthorizedError)
    expect(Whatsapp::CallingLifecycleJob).not_to have_been_enqueued
  end

  it 'returns ready without a provider operation when state is already converged' do
    channel.update!(provider_config: channel.provider_config.merge(
      'calling_requested_enabled' => true,
      'calling_enabled' => true,
      'calling_lifecycle_state' => 'ready'
    ))

    expect(request(enabled: true)).to eq(calling_requested_enabled: true, calling_lifecycle_state: 'ready')
    expect(Lla::Voice::CallOperation).not_to exist
    expect(Whatsapp::CallingLifecycleJob).not_to have_been_enqueued
  end
end
