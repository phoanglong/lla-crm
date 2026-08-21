# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::OutboundCallBuilder do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', account: account,
                              validate_provider_config: false, sync_templates: false)
  end
  let(:inbox) { channel.inbox }
  let(:user) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+15550001111') }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact, source_id: '15550001111') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      .reload
  end
  let(:conversation_builder) { instance_double(Whatsapp::CallConversationBuilder, perform!: conversation) }
  let(:provider_service) do
    instance_double(Whatsapp::Providers::WhatsappCloudService,
                    initiate_call: { 'calls' => [{ 'id' => 'wacid-builder-1' }] }, terminate_call: true)
  end
  let(:sdp_offer) { "v=0\r\no=lla 1 1 IN IP4 127.0.0.1\r\n" }

  before do
    account.enable_features!('channel_voice')
    channel.update!(provider_config: channel.provider_config.merge('calling_enabled' => true))
    create(:inbox_member, inbox: inbox, user: user)
    allow(channel).to receive(:provider_service).and_return(provider_service)
    allow(inbox).to receive(:channel).and_return(channel)
  end

  def perform_call(key: SecureRandom.uuid, **overrides)
    described_class.new(
      account: account, inbox: inbox, user: user, contact: contact,
      conversation: conversation, conversation_builder: conversation_builder,
      sdp_offer: sdp_offer, idempotency_key: key, **overrides
    ).perform!
  end

  it 'creates an owned call/message operation without persisting raw SDP' do
    call = perform_call

    expect(call).to have_attributes(provider_call_id: 'wacid-builder-1', direction: 'outgoing', status: 'ringing')
    expect(call.message).to be_present
    expect(call.meta).to eq('sdp_offer_digest' => Digest::SHA256.hexdigest(sdp_offer))
    expect(Lla::Voice::CallOperation.find_by(call: call)).to have_attributes(action: 'dial', state: 'succeeded')
  end

  it 'returns the same call without dialing twice for an idempotent retry' do
    key = 'idempotent-call-spec-1'

    first = perform_call(key: key)
    second = perform_call(key: key)

    expect(second).to eq(first)
    expect(provider_service).to have_received(:initiate_call).once
  end

  it 'rejects reuse of an idempotency key for a changed SDP' do
    key = 'idempotency-conflict-1'
    perform_call(key: key)

    expect do
      perform_call(key: key, sdp_offer: "v=0\r\no=changed 2 2 IN IP4 127.0.0.1\r\n")
    end.to raise_error(described_class::IdempotencyConflict)
    expect(provider_service).to have_received(:initiate_call).once
  end

  it 'rejects a cross-tenant contact before dialing' do
    other_contact = create(:contact, phone_number: '+15550002222')

    expect { perform_call(contact: other_contact) }.to raise_error(described_class::InvalidRequest, 'Account context mismatch')
    expect(provider_service).not_to have_received(:initiate_call)
  end

  it 'terminates the provider call when local persistence fails' do
    allow(Call).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(Call.new))

    expect { perform_call }.to raise_error(ActiveRecord::RecordInvalid)

    expect(provider_service).to have_received(:terminate_call).with('wacid-builder-1')
    expect(Lla::Voice::CallOperation.last.state).to eq('compensated')
  end

  it 'honors the operation backoff after a provider transport failure' do
    key = 'provider-backoff-call-1'
    allow(provider_service).to receive(:initiate_call).and_raise(Faraday::TimeoutError)

    expect { perform_call(key: key) }.to raise_error(Faraday::TimeoutError)
    expect { perform_call(key: key) }
      .to raise_error(described_class::OperationInProgress, 'Call request retry is temporarily unavailable')

    expect(provider_service).to have_received(:initiate_call).once
    expect(Lla::Voice::CallOperation.last.state).to eq('failed')
  end

  it 'returns recording authorization only after immutable consent is attached' do
    channel.update!(provider_config: channel.provider_config.merge(
      'voice_recording_enabled' => true,
      'voice_recording_disclosure_version' => 'lla-voice-v1'
    ))
    attestation = {
      accepted: true,
      attestation_id: 'whatsapp-recording-consent-1',
      attested_at: Time.current.iso8601,
      disclosure_version: 'lla-voice-v1',
      method: 'agent_attestation'
    }

    call = perform_call(recording_consent: attestation)

    expect(call.lla_recording_consent).to be_present
    expect(call.meta['recording_consent_id']).to eq(call.lla_recording_consent.id)
  end
end
