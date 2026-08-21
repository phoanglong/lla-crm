# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'LLA voice inbox configuration API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  before do
    account.enable_features!('channel_voice')
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(16)}"))
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes' do
    it 'creates a Twilio voice inbox for an administrator' do
      stub_request(:get, %r{api\.twilio\.com/2010-04-01/Accounts/.*/IncomingPhoneNumbers\.json})
        .to_return(status: 200, body: { incoming_phone_numbers: [{ capabilities: { 'voice' => true } }] }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/inboxes",
           headers: admin.create_new_auth_token,
           params: { name: 'Voice Inbox',
                     channel: { type: 'voice', phone_number: '+15551234567',
                                provider_config: { account_sid: "AC#{SecureRandom.hex(16)}",
                                                   auth_token: SecureRandom.hex(16),
                                                   api_key_sid: SecureRandom.hex(8),
                                                   api_key_secret: SecureRandom.hex(16) } } },
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('name' => 'Voice Inbox', 'phone_number' => '+15551234567')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/set_inbound_calls' do
    it 'updates a Twilio voice inbox without touching the provider' do
      channel = create(:channel_twilio_sms, :with_voice, account: account)

      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/set_inbound_calls",
           headers: admin.create_new_auth_token,
           params: { inbound_calls_enabled: false },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(channel.reload.inbound_calls_enabled?).to be false
    end

    it 'updates a WhatsApp inbox without re-validating provider credentials' do
      channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                          validate_provider_config: false, sync_templates: false)
      channel.update!(provider_config: channel.provider_config.merge('calling_enabled' => true,
                                                                     'inbound_calls_enabled' => false))

      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/set_inbound_calls",
           headers: admin.create_new_auth_token,
           params: { inbound_calls_enabled: true },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(channel.reload.inbound_calls_enabled?).to be true
    end

    it 'rejects an agent and leaves the setting unchanged' do
      agent = create(:user, account: account, role: :agent)
      channel = create(:channel_twilio_sms, :with_voice, account: account)

      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/set_inbound_calls",
           headers: agent.create_new_auth_token,
           params: { inbound_calls_enabled: false },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(channel.reload.inbound_calls_enabled?).to be true
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/set_voice_recording' do
    let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }

    it 'stores an explicit recording policy and disclosure version' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/set_voice_recording",
           headers: admin.create_new_auth_token,
           params: { voice_recording_enabled: true, disclosure_version: 'lla-voice-v1' },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(channel.reload.provider_config).to include(
        'voice_recording_enabled' => true,
        'voice_recording_disclosure_version' => 'lla-voice-v1'
      )

      get "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}",
          headers: admin.create_new_auth_token,
          as: :json
      expect(response.parsed_body).to include('voice_recording_enabled' => true,
                                              'voice_recording_disclosure_version' => 'lla-voice-v1')
    end

    it 'rejects an invalid disclosure version and preserves the current policy' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/set_voice_recording",
           headers: admin.create_new_auth_token,
           params: { voice_recording_enabled: true, disclosure_version: '../../unsafe value' },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(channel.reload.provider_config).not_to have_key('voice_recording_enabled')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/enable_whatsapp_calling' do
    let(:channel) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                validate_provider_config: false, sync_templates: false)
    end

    it 'accepts an idempotent asynchronous lifecycle request' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/enable_whatsapp_calling",
           headers: admin.create_new_auth_token.merge('Idempotency-Key' => 'enable-whatsapp-calling-1'),
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to include('calling_requested_enabled' => true,
                                              'calling_lifecycle_state' => 'pending')
      expect(Whatsapp::CallingLifecycleJob).to have_been_enqueued
      config = channel.reload.provider_config
      expect(config).to include('calling_requested_enabled' => true, 'calling_lifecycle_state' => 'pending')
      expect(ActiveModel::Type::Boolean.new.cast(config['calling_enabled'])).to be false
    end

    it 'rejects a request without an idempotency key' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/enable_whatsapp_calling",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Whatsapp::CallingLifecycleJob).not_to have_been_enqueued
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/set_whatsapp_calling_message' do
    let(:channel) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                validate_provider_config: false, sync_templates: false)
    end

    it 'updates only the permission message under the channel lock' do
      original_api_key = channel.provider_config['api_key']

      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/set_whatsapp_calling_message",
           headers: admin.create_new_auth_token,
           params: { call_permission_request_body: '  May LLA call you?  ' },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(channel.reload.provider_config).to include('api_key' => original_api_key,
                                                        'call_permission_request_body' => 'May LLA call you?')
    end

    it 'rejects an oversized message without changing provider configuration' do
      original_config = channel.provider_config

      post "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/set_whatsapp_calling_message",
           headers: admin.create_new_auth_token,
           params: { call_permission_request_body: 'x' * 1025 },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(channel.reload.provider_config).to eq(original_config)
    end
  end
end
