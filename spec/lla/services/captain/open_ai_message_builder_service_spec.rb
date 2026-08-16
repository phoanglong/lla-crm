# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::OpenAiMessageBuilderService, type: :service do
  subject(:service) { described_class.new(message: message) }

  let(:message) { create(:message, content: 'hello') }

  it 'bounds text sent to the model' do
    message.update!(content: 'a' * (described_class::MAX_TEXT_CHARACTERS + 100))

    expect(service.generate_content.length).to eq(described_class::MAX_TEXT_CHARACTERS)
  end

  it 'rejects an unsafe image URL instead of passing it to the model' do
    attachment = message.attachments.create!(
      account: message.account,
      file_type: :image,
      external_url: 'http://127.0.0.1/private.png'
    )

    expect(Lla::Network::UrlSafety).not_to receive(:validate!)
    expect(service.send(:get_attachment_url, attachment)).to be_nil
  end

  it 'uses the URL safety guard for HTTPS image URLs' do
    attachment = message.attachments.create!(
      account: message.account,
      file_type: :image,
      external_url: 'https://cdn.example.test/image.png'
    )
    allow(Lla::Network::UrlSafety).to receive(:validate!).and_return(true)

    expect(service.send(:get_attachment_url, attachment)).to eq('https://cdn.example.test/image.png')
    expect(Lla::Network::UrlSafety).to have_received(:validate!).with('https://cdn.example.test/image.png')
  end

  it 'normalizes whitespace between multiple audio transcriptions' do
    audio_one = message.attachments.create!(account: message.account, file_type: :audio)
    audio_two = message.attachments.create!(account: message.account, file_type: :audio)
    allow(Messages::AudioTranscriptionService).to receive(:new).with(audio_one).and_return(
      instance_double(Messages::AudioTranscriptionService, perform: { success: true, transcriptions: 'first ' })
    )
    allow(Messages::AudioTranscriptionService).to receive(:new).with(audio_two).and_return(
      instance_double(Messages::AudioTranscriptionService, perform: { success: true, transcriptions: ' second' })
    )

    expect(service.send(:extract_audio_transcriptions, message.attachments)).to eq('first second')
  end
end
