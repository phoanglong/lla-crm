# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Twilio::VoiceController', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account, phone_number: '+15551230003') }
  let(:inbox) { channel.inbox }
  let(:digits) { channel.phone_number.delete_prefix('+') }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(16)}"))
    account.enable_features!('channel_voice')
  end

  def signed_post(path, params, signed_url: nil)
    url = signed_url || "http://localhost:3000#{path}"
    signature = Twilio::Security::RequestValidator.new(channel.auth_token).build_signature_for(url, params)
    post path, params: params, headers: { 'X-Twilio-Signature' => signature }
  end

  describe 'POST /twilio/voice/call/:phone' do
    let(:call_sid) { 'CA_test_call_sid_123' }
    let(:from_number) { '+15550003333' }
    let(:to_number) { channel.phone_number }

    it 'invokes Voice::InboundCallBuilder for inbound calls and renders conference TwiML' do
      conversation = create(:conversation, account: account, inbox: inbox)
      contact = conversation.contact
      call = create(
        :call,
        account: account,
        inbox: inbox,
        conversation: conversation,
        contact: contact,
        provider_call_id: call_sid
      )
      call.update!(conference_sid: call.default_conference_sid)

      expect(Voice::InboundCallBuilder).to receive(:perform!).with(
        inbox: inbox,
        call_sid: call_sid,
        caller: { source_ids: [from_number], contact_attributes: { name: from_number, phone_number: from_number } }
      ).and_return(call)

      path = "/twilio/voice/call/#{digits}"
      signed_post path, {
        'CallSid' => call_sid,
        'From' => from_number,
        'To' => to_number,
        'Direction' => 'inbound'
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<Response>')
      expect(response.body).to include('<Dial>')
      expect(response.body).to include(call.conference_sid)
      expect(Lla::Voice::CallEvent.last).to have_attributes(outcome: 'applied', call_id: call.id)
    end

    it 'keeps recording off by default and omits the recording callback' do
      conversation = create(:conversation, account: account, inbox: inbox)
      call = create(:call, account: account, inbox: inbox, conversation: conversation,
                           contact: conversation.contact, provider_call_id: call_sid)
      allow(Voice::InboundCallBuilder).to receive(:perform!).and_return(call)

      signed_post "/twilio/voice/call/#{digits}", {
        'CallSid' => call_sid,
        'From' => from_number,
        'Direction' => 'inbound'
      }

      expect(response.body).to include('record="do-not-record"')
      expect(response.body).not_to include('recordingStatusCallback')
    end

    it 'looks up the Call when Twilio sends the outbound-api PSTN leg' do
      conversation = create(:conversation, account: account, inbox: inbox)
      call = create(
        :call,
        account: account,
        inbox: inbox,
        conversation: conversation,
        contact: conversation.contact,
        direction: :outgoing,
        provider_call_id: call_sid
      )
      call.update!(conference_sid: call.default_conference_sid)

      signed_post "/twilio/voice/call/#{digits}", {
        'CallSid' => call_sid,
        'From' => to_number,
        'To' => from_number,
        'Direction' => 'outbound-api'
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(call.conference_sid)
      expect(call.reload.parent_call_sid).to be_nil
    end

    it 'records the parent call SID when syncing outbound-dial legs' do
      parent_sid = 'CA_parent'
      child_sid = 'CA_child'
      conversation = create(:conversation, account: account, inbox: inbox)
      call = create(
        :call,
        account: account,
        inbox: inbox,
        conversation: conversation,
        contact: conversation.contact,
        direction: :outgoing,
        provider_call_id: parent_sid
      )
      call.update!(conference_sid: call.default_conference_sid)

      signed_post "/twilio/voice/call/#{digits}", {
        'CallSid' => child_sid,
        'ParentCallSid' => parent_sid,
        'From' => to_number,
        'To' => from_number,
        'Direction' => 'outbound-dial'
      }

      expect(response).to have_http_status(:ok)
      expect(call.reload.parent_call_sid).to eq(parent_sid)
    end

    it 'fails closed without revealing whether an inbox exists' do
      expect(Voice::InboundCallBuilder).not_to receive(:perform!)
      post '/twilio/voice/call/19998887777', params: {
        'CallSid' => call_sid,
        'From' => from_number,
        'To' => to_number,
        'Direction' => 'inbound'
      }
      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects the inbound contact leg without building a call when inbound calls are disabled' do
      channel.update!(provider_config: { 'inbound_calls_enabled' => false })
      expect(Voice::InboundCallBuilder).not_to receive(:perform!)

      expect do
        signed_post "/twilio/voice/call/#{digits}", {
          'CallSid' => call_sid,
          'From' => from_number,
          'To' => to_number,
          'Direction' => 'inbound'
        }
      end.not_to change(Call, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<Reject')
    end

    it 'rejects invalid signatures before creating a call or event' do
      expect do
        post "/twilio/voice/call/#{digits}",
             params: { 'CallSid' => call_sid, 'From' => from_number, 'Direction' => 'inbound' },
             headers: { 'X-Twilio-Signature' => 'invalid' }
      end.to not_change(Call, :count).and not_change(Lla::Voice::CallEvent, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects a signature computed for a different public URL' do
      signed_post "/twilio/voice/call/#{digits}",
                  { 'CallSid' => call_sid, 'From' => from_number, 'Direction' => 'inbound' },
                  signed_url: "https://wrong.example/twilio/voice/call/#{digits}"

      expect(response).to have_http_status(:forbidden)
    end

    it 'fails closed when the account voice capability is disabled' do
      account.disable_features!('channel_voice')

      signed_post "/twilio/voice/call/#{digits}", {
        'CallSid' => call_sid,
        'From' => from_number,
        'Direction' => 'inbound'
      }

      expect(response).to have_http_status(:forbidden)
      expect(Lla::Voice::CallEvent.last.outcome).to eq('rejected')
    end

    it 'records only when policy and explicit consent evidence are present' do
      conversation = create(:conversation, account: account, inbox: inbox)
      call = create(:call, account: account, inbox: inbox, conversation: conversation,
                           contact: conversation.contact, provider_call_id: call_sid,
                           meta: { 'recording_consent_id' => 'consent-test-1' })
      channel.update!(provider_config: channel.provider_config.merge('voice_recording_enabled' => true))
      allow(Voice::InboundCallBuilder).to receive(:perform!).and_return(call)

      signed_post "/twilio/voice/call/#{digits}", {
        'CallSid' => call_sid,
        'From' => from_number,
        'Direction' => 'inbound'
      }

      expect(response.body).to include('record="record-from-start"', 'recordingStatusCallback')
    end
  end

  describe 'POST /twilio/voice/status/:phone' do
    let(:call_sid) { 'CA_status_sid_456' }

    it 'invokes Voice::StatusUpdateService with expected params' do
      service_double = instance_double(Voice::StatusUpdateService, perform: nil)
      expect(Voice::StatusUpdateService).to receive(:new).with(
        hash_including(
          account: account,
          inbox: inbox,
          call_sid: call_sid,
          call_status: 'completed',
          payload: hash_including('CallSid' => call_sid, 'CallStatus' => 'completed')
        )
      ).and_return(service_double)
      expect(service_double).to receive(:perform)

      signed_post "/twilio/voice/status/#{digits}", {
        'CallSid' => call_sid,
        'CallStatus' => 'completed'
      }

      expect(response).to have_http_status(:no_content)
    end

    it 'fails closed when the channel does not exist' do
      expect(Voice::StatusUpdateService).not_to receive(:new)
      post '/twilio/voice/status/18005550101', params: {
        'CallSid' => call_sid,
        'CallStatus' => 'busy'
      }
      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects an already applied callback replay without a second side effect' do
      service = instance_double(Voice::StatusUpdateService, perform: nil)
      expect(Voice::StatusUpdateService).to receive(:new).once.and_return(service)
      params = { 'CallSid' => call_sid, 'CallStatus' => 'completed' }
      path = "/twilio/voice/status/#{digits}"

      signed_post(path, params)
      expect(response).to have_http_status(:no_content)
      signed_post(path, params)

      expect(response).to have_http_status(:forbidden)
      event = Lla::Voice::CallEvent.last
      expect(event).to have_attributes(outcome: 'applied', event_type: 'twilio.status')
      expect(event.attributes).not_to include('payload', 'raw_payload')
    end
  end
end
