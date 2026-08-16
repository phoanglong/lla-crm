# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::RecordingAttachmentService do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', account: account,
                              validate_provider_config: false, sync_templates: false)
  end
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: account, inbox: channel.inbox, conversation: conversation,
                     content_type: 'voice_call', message_type: 'incoming')
  end
  let(:call) do
    create(:call, account: account, inbox: channel.inbox, conversation: conversation, contact: conversation.contact,
                  message: message, provider: :whatsapp, provider_call_id: 'wacid-recording-1', status: 'completed',
                  meta: { 'recording_consent_id' => 'consent-spec-1' })
  end
  let(:upload) { fixture_file_upload(Rails.root.join('spec/assets/sample.mp3'), 'application/octet-stream') }

  before do
    channel.update!(provider_config: channel.provider_config.merge('voice_recording_enabled' => true))
    allow(Lla::Security::MalwareScanner).to receive(:scan!).and_return(true)
  end

  it 'sniffs, scans, and attaches audio under an internal filename' do
    status = described_class.new(call: call, upload: upload).perform
    attachment = message.attachments.last

    expect(status).to eq('uploaded')
    expect(Lla::Security::MalwareScanner).to have_received(:scan!)
    expect(attachment.file.content_type).to start_with('audio/')
    expect(attachment.file.filename.to_s).to start_with("whatsapp-call-recording-#{call.id}.")
  end

  it 'is idempotent when an audio attachment already exists' do
    service = described_class.new(call: call, upload: upload)

    expect(service.perform).to eq('uploaded')
    expect(service.perform).to eq('already_uploaded')
    expect(message.attachments.audio.count).to eq(1)
  end

  it 'rejects recording when policy or consent is missing' do
    call.update!(meta: {})

    expect { described_class.new(call: call, upload: upload).perform }
      .to raise_error(described_class::NotAllowed)
    expect(Lla::Security::MalwareScanner).not_to have_received(:scan!)
  end

  it 'rejects content whose bytes are not audio despite its declared MIME' do
    fake_audio = fixture_file_upload(Rails.root.join('spec/assets/sample.pdf'), 'audio/mpeg')

    expect { described_class.new(call: call, upload: fake_audio).perform }
      .to raise_error(described_class::InvalidRecording, 'Recording content is not audio')
  end

  it 'fails closed when the malware scanner is unavailable' do
    allow(Lla::Security::MalwareScanner).to receive(:scan!)
      .and_raise(Lla::Security::MalwareScanner::ScannerUnavailable)

    expect { described_class.new(call: call, upload: upload).perform }
      .to raise_error(Lla::Security::MalwareScanner::ScannerUnavailable)
    expect(message.attachments.audio).to be_empty
  end
end
