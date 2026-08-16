# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::RecordingStatusService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account, phone_number: '+15551237777') }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:conference_sid) { 'CFabc123def456' }
  let!(:call) do
    create(
      :call,
      account: account,
      inbox: inbox,
      conversation: conversation,
      contact: conversation.contact,
      meta: { 'twilio_conference_sid' => conference_sid, 'recording_consent_id' => 'consent-test-1' }
    )
  end

  let(:recording_sid) { 'RE1234567890abcdef' }
  let(:recording_duration) { '12' }

  let(:complete_payload) do
    {
      'RecordingStatus' => 'completed',
      'ConferenceSid' => conference_sid,
      'RecordingSid' => recording_sid,
      'RecordingUrl' => 'https://attacker.invalid/ignored',
      'RecordingDuration' => recording_duration
    }
  end

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(8)}"))
    channel.update!(provider_config: channel.provider_config.merge('voice_recording_enabled' => true))
  end

  describe '#perform' do
    it 'enqueues the recording attachment job for the matching call' do
      expect do
        described_class.new(account: account, inbox: inbox, payload: complete_payload).perform
      end.to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
        .with(call.id, recording_sid, recording_duration)
    end

    it 'is a no-op when RecordingStatus is not completed' do
      payload = complete_payload.merge('RecordingStatus' => 'in-progress')

      expect do
        described_class.new(account: account, inbox: inbox, payload: payload).perform
      end.not_to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
    end

    it 'is a no-op when ConferenceSid is missing' do
      payload = complete_payload.except('ConferenceSid')

      expect do
        described_class.new(account: account, inbox: inbox, payload: payload).perform
      end.not_to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
    end

    it 'is a no-op when RecordingSid is missing' do
      payload = complete_payload.except('RecordingSid')

      expect do
        described_class.new(account: account, inbox: inbox, payload: payload).perform
      end.not_to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
    end

    it 'does not place the provider recording URL in the job payload' do
      payload = complete_payload.except('RecordingUrl')

      expect do
        described_class.new(account: account, inbox: inbox, payload: payload).perform
      end.to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
        .with(call.id, recording_sid, recording_duration)
    end

    it 'is a no-op when no Call matches the ConferenceSid' do
      payload = complete_payload.merge('ConferenceSid' => 'CFunknown')

      expect do
        described_class.new(account: account, inbox: inbox, payload: payload).perform
      end.not_to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
    end

    it 'is a no-op without explicit recording consent' do
      call.update!(meta: call.meta.except('recording_consent_id'))

      expect do
        described_class.new(account: account, inbox: inbox, payload: complete_payload).perform
      end.not_to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
    end

    it 'does not follow a conference identifier into another inbox' do
      other_inbox = create(:inbox, account: account)

      expect do
        described_class.new(account: account, inbox: other_inbox, payload: complete_payload).perform
      end.not_to have_enqueued_job(Voice::Provider::Twilio::RecordingAttachmentJob)
    end
  end
end
