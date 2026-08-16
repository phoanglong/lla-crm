# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::Provider::Twilio::RecordingAttachmentService do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_twilio_sms, :with_voice,
           account: account,
           phone_number: '+15551238888',
           account_sid: 'AC1234567890abcdef',
           auth_token: 'auth_token_value')
  end
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call) do
    create(
      :call,
      account: account,
      inbox: inbox,
      conversation: conversation,
      contact: conversation.contact,
      meta: { 'recording_consent_id' => 'consent-test-1' }
    )
  end
  let!(:message) do
    msg = conversation.messages.create!(
      account_id: account.id,
      inbox_id: inbox.id,
      message_type: :incoming,
      sender: conversation.contact,
      content: 'Voice Call',
      content_type: 'voice_call'
    )
    call.update!(message_id: msg.id)
    msg
  end

  let(:recording_sid) { 'RE9999' }
  let(:recording_url) { 'https://api.twilio.com/2010-04-01/Accounts/AC1234567890abcdef/Recordings/RE9999' }
  let(:recording_duration) { '47' }

  let(:downloaded_tempfile) do
    file = Tempfile.new(['call-recording', '.wav'])
    file.binmode
    file.write("RIFF\x24\x00\x00\x00WAVEfmt ")
    file.rewind
    file
  end

  let(:safe_fetch_result) do
    SafeFetch::Result.new(
      tempfile: downloaded_tempfile,
      filename: 'recording.wav',
      content_type: 'audio/wav'
    )
  end

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(8)}"))
    channel.update!(provider_config: channel.provider_config.merge('voice_recording_enabled' => true))

    allow(SafeFetch).to receive(:fetch)
      .with(recording_url, http_basic_authentication: %w[AC1234567890abcdef auth_token_value],
                           allowed_content_type_prefixes: %w[audio/], max_bytes: 25.megabytes)
      .and_yield(safe_fetch_result)
    allow(Lla::Security::MalwareScanner).to receive(:scan!).and_return(true)
  end

  def perform_service(overrides = {})
    described_class.new(
      call: call,
      recording_sid: overrides.fetch(:recording_sid, recording_sid),
      recording_duration: overrides.fetch(:recording_duration, recording_duration)
    ).perform
  end

  describe '#perform' do
    it 'attaches the recording to the call and persists recording_sid + duration_seconds' do
      previous_updated_at = message.updated_at
      travel 1.second

      perform_service

      call.reload
      message.reload

      aggregate_failures do
        expect(call.recording).to be_attached
        expect(call.recording_sid).to eq(recording_sid)
        expect(call.duration_seconds).to eq(47)
        expect(message.updated_at).to be > previous_updated_at
      end
    end

    it 'preserves a duration_seconds value that was already set on the call' do
      call.update!(duration_seconds: 99)

      perform_service

      expect(call.reload.duration_seconds).to eq(99)
    end

    it 'is idempotent when the same recording_sid is already attached' do
      perform_service

      expect(SafeFetch).to have_received(:fetch).once

      perform_service

      expect(SafeFetch).to have_received(:fetch).once
      expect(call.reload.recording.blob.checksum).to be_present
    end

    it 'is a no-op when recording_sid is blank' do
      expect { perform_service(recording_sid: '') }.not_to change { call.reload.recording.attached? }.from(false)
      expect(SafeFetch).not_to have_received(:fetch)
    end

    it 'is a no-op when recording consent is missing' do
      call.update!(meta: call.meta.except('recording_consent_id'))

      expect { perform_service }.not_to change { call.reload.recording.attached? }.from(false)
      expect(SafeFetch).not_to have_received(:fetch)
    end

    it 'is a no-op for a malformed provider recording identifier' do
      expect { perform_service(recording_sid: '../secret') }.not_to change { call.reload.recording.attached? }.from(false)
      expect(SafeFetch).not_to have_received(:fetch)
    end

    it 'rejects content whose bytes are not an audio format' do
      downloaded_tempfile.rewind
      downloaded_tempfile.truncate(0)
      downloaded_tempfile.write("MZ\x00\x00NOT_AUDIO")
      downloaded_tempfile.rewind

      expect { perform_service }.to raise_error(SafeFetch::UnsupportedContentTypeError)
      expect(call.reload.recording).not_to be_attached
    end

    it 'fails closed when malware scanning is unavailable' do
      allow(Lla::Security::MalwareScanner).to receive(:scan!).and_raise(Lla::Security::MalwareScanner::ScannerUnavailable)

      expect { perform_service }.to raise_error(Lla::Security::MalwareScanner::ScannerUnavailable)
      expect(call.reload.recording).not_to be_attached
    end
  end
end
