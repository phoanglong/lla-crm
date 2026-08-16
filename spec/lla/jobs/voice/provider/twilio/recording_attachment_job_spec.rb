# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::Provider::Twilio::RecordingAttachmentJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:call) do
    create(:call, account: account, inbox: channel.inbox, conversation: conversation, contact: conversation.contact)
  end
  let(:attachment_service) { instance_double(Voice::Provider::Twilio::RecordingAttachmentService, perform: true) }

  before do
    allow(Voice::Provider::Twilio::RecordingAttachmentService).to receive(:new).and_return(attachment_service)
  end

  it 'fetches once for duplicate delivery and records the operation outcome' do
    job = described_class.new
    job.perform(call.id, 'RE9999', '42')
    job.perform(call.id, 'RE9999', '42')

    operation = Lla::Voice::CallOperation.find_by!(call: call, action: 'fetch_recording')
    expect(operation).to have_attributes(state: 'succeeded', attempts: 1)
    expect(attachment_service).to have_received(:perform).once
  end

  it 'records scanner failures without storing provider payloads' do
    allow(attachment_service).to receive(:perform).and_raise(Lla::Security::MalwareScanner::ScannerUnavailable)

    expect { described_class.new.perform(call.id, 'RE9999', '42') }
      .to raise_error(Lla::Security::MalwareScanner::ScannerUnavailable)

    operation = Lla::Voice::CallOperation.find_by!(call: call, action: 'fetch_recording')
    expect(operation.state).to eq('failed')
    expect(operation.attributes.keys).not_to include('payload', 'recording_url')
  end
end
