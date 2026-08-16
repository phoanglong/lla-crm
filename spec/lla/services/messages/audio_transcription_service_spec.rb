# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::AudioTranscriptionService, type: :service do
  let(:account) { create(:account, audio_transcriptions: true, limits: { captain_responses: 2 }) }
  let(:message) { create(:message, account: account) }
  let(:attachment) { message.attachments.create!(account: account, file_type: :audio) }
  let(:service) { described_class.new(attachment) }

  before do
    account.enable_features!('captain_integration')
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-api-key')
  end

  it 'rejects an attachment whose tenant does not match its message' do
    foreign_attachment = message.attachments.create!(account: create(:account), file_type: :audio)

    expect(described_class.new(foreign_attachment).perform).to eq(error: 'Invalid audio attachment context')
  end

  it 'returns a cached transcription without constructing a provider client or requiring a file' do
    attachment.update!(meta: { 'transcribed_text' => 'cached text' })
    allow(OpenAI::Client).to receive(:new)

    expect(service.perform).to eq(success: true, transcriptions: 'cached text')
    expect(OpenAI::Client).not_to have_received(:new)
  end

  it 'preserves attachment metadata and only accounts for the first persisted transcription' do
    attachment.file.attach(
      io: File.open(Rails.public_path.join('audio/widget/ding.mp3')),
      filename: 'voice.mp3',
      content_type: 'audio/mpeg'
    )
    attachment.update!(meta: { 'duration' => 12 })

    expect(service.send(:update_transcription, 'first')).to eq('first')
    expect(service.send(:update_transcription, 'second')).to eq('first')

    expect(attachment.reload.meta).to include('duration' => 12, 'transcribed_text' => 'first')
    expect(account.reload.custom_attributes['captain_responses_usage']).to eq(1)
  end

  it 'rejects non-HTTPS provider endpoints and embedded credentials' do
    endpoint = create(:installation_config, name: 'CAPTAIN_OPEN_AI_ENDPOINT', value: 'http://api.example.test/')
    expect { service.client }.to raise_error(ArgumentError, 'Audio transcription endpoint must use HTTPS')

    endpoint.update!(value: 'https://user:password@api.example.test/')
    expect { described_class.new(attachment).client }
      .to raise_error(ArgumentError, 'Audio transcription endpoint must use HTTPS')
  end

  it 'sanitizes the temporary filename extension' do
    blob = instance_double(
      ActiveStorage::Blob,
      filename: ActiveStorage::Filename.new('voice.../../../secret.MP3'),
      content_type: 'audio/mpeg'
    )

    expect(service.send(:safe_extension, blob)).to eq('.mp3')
  end
end
