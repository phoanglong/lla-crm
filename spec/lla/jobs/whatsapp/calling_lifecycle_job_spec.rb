# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::CallingLifecycleJob do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                              validate_provider_config: false, sync_templates: false)
  end
  let(:provider_service) do
    instance_double(Whatsapp::Providers::WhatsappCloudService, update_calling_status: true)
  end
  let(:webhook_service) { instance_double(Whatsapp::WebhookSetupService, register_callback: true) }

  before do
    account.enable_features!('channel_voice')
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider_service)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
  end

  def operation_for(enabled:, key: SecureRandom.uuid)
    Whatsapp::CallingLifecycleRequestService.new(
      inbox: channel.inbox, user: admin, enabled: enabled, idempotency_key: key
    ).perform
    Lla::Voice::CallOperation.order(:id).last
  end

  it 'converges Meta and the local effective state exactly once' do
    operation = operation_for(enabled: true, key: 'lifecycle-enable-1')

    described_class.new.perform(operation.id)
    described_class.new.perform(operation.id)

    expect(operation.reload).to have_attributes(state: 'succeeded', attempts: 1)
    expect(channel.reload.provider_config).to include('calling_requested_enabled' => true,
                                                      'calling_enabled' => true,
                                                      'calling_lifecycle_state' => 'ready')
    expect(provider_service).to have_received(:update_calling_status).with('ENABLED').once
    expect(webhook_service).to have_received(:register_callback).once
  end

  it 'compensates a superseded enable request without calling Meta' do
    enable_operation = operation_for(enabled: true, key: 'lifecycle-stale-enable-1')
    operation_for(enabled: false, key: 'lifecycle-disable-2')

    described_class.perform_now(enable_operation.id)

    expect(enable_operation.reload.state).to eq('compensated')
    expect(provider_service).not_to have_received(:update_calling_status)
  end

  it 'fails closed and records a retryable error when enabling Meta fails' do
    operation = operation_for(enabled: true, key: 'lifecycle-enable-failure-1')
    allow(provider_service).to receive(:update_calling_status) do |status|
      raise Faraday::TimeoutError if status == 'ENABLED'

      true
    end

    expect { described_class.new.perform(operation.id) }.to raise_error(Faraday::TimeoutError)

    expect(operation.reload).to have_attributes(state: 'failed', last_error_code: 'Faraday::TimeoutError')
    expect(operation.available_at).to be > Time.current
    expect(channel.reload.provider_config).to include('calling_enabled' => false,
                                                      'calling_lifecycle_state' => 'failed',
                                                      'calling_lifecycle_error_code' => 'Faraday::TimeoutError')
    expect(provider_service).to have_received(:update_calling_status).with('DISABLED').once
  end
end
