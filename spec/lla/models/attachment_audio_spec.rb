# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Attachment, type: :model do
  include ActiveJob::TestHelper

  let(:message) { create(:message) }

  before { clear_enqueued_jobs }

  it 'enqueues exactly one low-priority transcription job for an audio attachment' do
    attachment = nil

    expect do
      attachment = message.attachments.create!(account: message.account, file_type: :audio)
    end.to have_enqueued_job(Messages::AudioTranscriptionJob).once.on_queue('low')

    expect(enqueued_jobs.last[:args]).to eq([attachment.id])
  end

  it 'does not enqueue transcription for a non-audio attachment' do
    expect do
      message.attachments.create!(account: message.account, file_type: :file)
    end.not_to have_enqueued_job(Messages::AudioTranscriptionJob)
  end
end
