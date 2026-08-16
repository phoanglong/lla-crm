# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Twilio::VoiceLifecycleJob do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account, twiml_app_sid: nil) }
  let(:setup_service) { instance_double(Twilio::VoiceWebhookSetupService, perform: 'AP12345678') }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new).and_return(setup_service)
    account.enable_features!('channel_voice')
  end

  it 'claims and completes an idempotent provisioning operation' do
    digest = channel.voice_configuration_digest

    described_class.perform_now(channel.id, 'provision', digest)
    described_class.perform_now(channel.id, 'provision', digest)

    operation = Lla::Voice::CallOperation.find_by!(inbox: channel.inbox, action: 'provision')
    expect(operation.state).to eq('succeeded')
    expect(operation.attempts).to eq(1)
    expect(channel.reload.twiml_app_sid).to eq('AP12345678')
    expect(setup_service).to have_received(:perform).once
  end

  it 'marks a superseded job compensated without touching the provider' do
    stale_digest = channel.voice_configuration_digest
    channel.update!(phone_number: '+15550003333')

    described_class.perform_now(channel.id, 'provision', stale_digest)

    operation = Lla::Voice::CallOperation.find_by!(inbox: channel.inbox, request_digest: stale_digest)
    expect(operation.state).to eq('compensated')
    expect(setup_service).not_to have_received(:perform)
  end
end
