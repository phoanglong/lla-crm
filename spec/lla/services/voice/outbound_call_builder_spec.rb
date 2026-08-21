# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::OutboundCallBuilder do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account, phone_number: '+15551230000') }
  let(:inbox) { channel.inbox }
  let(:user) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+15550001111') }
  let(:call_sid) { 'CA1234567890abcdef' }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(8)}"))
    allow(inbox).to receive(:channel).and_return(channel)
    allow(channel).to receive(:initiate_call).and_return({ call_sid: call_sid })
    account.enable_features!('channel_voice')
    create(:inbox_member, inbox: inbox, user: user)
  end

  def perform_call(**overrides)
    described_class.perform!(
      account: account,
      inbox: inbox,
      user: user,
      contact: contact,
      idempotency_key: SecureRandom.uuid,
      **overrides
    )
  end

  describe '.perform!' do
    it 'creates a conversation, Call, and voice_call message' do
      call = nil
      expect do
        call = perform_call
      end.to change(account.conversations, :count).by(1).and change(Call, :count).by(1)

      aggregate_failures do
        expect(call).to be_a(Call)
        expect(call.provider_call_id).to eq(call_sid)
        expect(call.direction).to eq('outgoing')
        expect(call.status).to eq('ringing')
        expect(call.accepted_by_agent_id).to eq(user.id)
        expect(call.conference_sid).to eq("conf_account_#{account.id}_call_#{call.id}")

        voice_message = call.conversation.messages.voice_calls.last
        expect(call.message_id).to eq(voice_message.id)
        expect(voice_message.message_type).to eq('outgoing')
        expect(voice_message.call).to eq(call)
      end
    end

    it 'assigns the conversation to the agent placing the call' do
      call = perform_call

      expect(call.conversation.assignee_id).to eq(user.id)
    end

    it 'keeps the calling agent assigned even when auto-assignment would pick an online agent' do
      other_agent = create(:user, account: account)
      create(:inbox_member, inbox: inbox, user: other_agent)
      inbox.update!(enable_auto_assignment: true)
      # Only other_agent is online, so round-robin would claim the conversation unless the caller wins at creation.
      OnlineStatusTracker.update_presence(account.id, 'User', other_agent.id)
      OnlineStatusTracker.set_status(account.id, other_agent.id, 'online')

      call = perform_call

      expect(call.conversation.assignee_id).to eq(user.id)
    end

    it 'claims a reused conversation for the caller when it is unassigned' do
      # Reload so the builder gets a DB-fresh record, mirroring the controller's find_by load.
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact).reload

      perform_call(conversation: conversation)

      expect(conversation.reload.assignee_id).to eq(user.id)
    end

    it 'keeps the existing assignee when a reused conversation is already assigned' do
      other_agent = create(:user, account: account)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, assignee: other_agent).reload

      perform_call(conversation: conversation)

      expect(conversation.reload.assignee_id).to eq(other_agent.id)
    end

    it 'does not set conversation.identifier or write call state to additional_attributes' do
      call = perform_call

      expect(call.conversation.identifier).to be_nil
      expect(call.conversation.additional_attributes).not_to include('call_status', 'call_direction', 'agent_id', 'conference_sid')
    end

    it 'raises an error when contact is missing a phone number' do
      contact.update!(phone_number: nil)

      expect do
        perform_call
      end.to raise_error(ArgumentError, 'Contact phone number required')
    end

    it 'raises an error when user is nil' do
      expect do
        perform_call(user: nil)
      end.to raise_error(ArgumentError, 'Agent required')
    end

    it 'rejects a request without an idempotency key before calling the provider' do
      expect { perform_call(idempotency_key: nil) }.to raise_error(ArgumentError, 'Idempotency-Key required')

      expect(channel).not_to have_received(:initiate_call)
    end

    it 'rejects cross-tenant contacts before calling the provider' do
      other_contact = create(:contact, phone_number: '+15550002222')

      expect { perform_call(contact: other_contact) }.to raise_error(ArgumentError, 'Account context mismatch')

      expect(channel).not_to have_received(:initiate_call)
    end

    it 'returns the original call when the same idempotency key is retried' do
      key = SecureRandom.uuid
      first_call = perform_call(idempotency_key: key)
      second_call = perform_call(idempotency_key: key)

      expect(second_call).to eq(first_call)
      expect(channel).to have_received(:initiate_call).once
      expect(Lla::Voice::CallOperation.find_by(call: first_call).state).to eq('succeeded')
    end

    it 'compensates the provider call when local persistence fails' do
      adapter = instance_double(Voice::Provider::Twilio::Adapter, terminate_call: true)
      allow(Voice::Provider::Twilio::Adapter).to receive(:new).and_return(adapter)
      allow(Call).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(Call.new))

      expect { perform_call }.to raise_error(ActiveRecord::RecordInvalid)

      expect(adapter).to have_received(:terminate_call).with(call_sid)
      expect(Lla::Voice::CallOperation.last.state).to eq('compensated')
    end

    it 'honors the operation backoff after a provider transport failure' do
      key = 'twilio-provider-backoff-1'
      allow(channel).to receive(:initiate_call).and_raise(Faraday::TimeoutError)

      expect { perform_call(idempotency_key: key) }.to raise_error(Faraday::TimeoutError)
      expect { perform_call(idempotency_key: key) }
        .to raise_error(described_class::OperationInProgress, 'Call request retry is temporarily unavailable')

      expect(channel).to have_received(:initiate_call).once
      expect(Lla::Voice::CallOperation.last).to have_attributes(state: 'failed', claim_digest: nil)
    end

    it 'attaches immutable recording evidence only for the current approved policy' do
      channel.update!(provider_config: channel.provider_config.merge(
        'voice_recording_enabled' => true,
        'voice_recording_disclosure_version' => 'lla-voice-v1'
      ))
      attestation = {
        accepted: true,
        attestation_id: 'twilio-recording-consent-1',
        attested_at: Time.current.iso8601,
        disclosure_version: 'lla-voice-v1',
        method: 'agent_attestation'
      }

      call = perform_call(recording_consent: attestation)

      consent = call.lla_recording_consent
      expect(consent).to be_present
      expect(call.meta['recording_consent_id']).to eq(consent.id)
    end
  end
end
