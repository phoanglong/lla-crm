# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::AudioTranscriptionJob, type: :job do
  it 'does not instantiate the service after an attachment has been deleted' do
    expect(Messages::AudioTranscriptionService).not_to receive(:new)

    described_class.perform_now(-1)
  end

  it 'passes the tenant-scoped attachment record to the service' do
    message = create(:message)
    attachment = message.attachments.create!(account: message.account, file_type: :audio)
    service = instance_double(Messages::AudioTranscriptionService, perform: { success: true })
    allow(Messages::AudioTranscriptionService).to receive(:new).with(attachment).and_return(service)

    described_class.perform_now(attachment.id)

    expect(service).to have_received(:perform)
  end
end
