# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::WhatsappEventsJob do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', account: account,
                              validate_provider_config: false, sync_templates: false)
  end
  let(:payload) do
    {
      object: 'whatsapp_business_account',
      entry: [{
        changes: [{
          field: 'calls',
          value: {
            metadata: {
              phone_number_id: channel.provider_config['phone_number_id'],
              display_phone_number: channel.phone_number.delete('+')
            },
            calls: [{ id: 'wacid-job-1', event: 'terminate', duration: 0, terminate_reason: 'no_answer' }]
          }
        }]
      }]
    }
  end
  let(:event) do
    Lla::Voice::CallEvent.create!(
      account: account, inbox: channel.inbox, provider: :whatsapp,
      event_id_digest: Digest::SHA256.hexdigest('event-job-1'),
      payload_digest: Digest::SHA256.hexdigest(payload.to_json),
      event_type: 'whatsapp.calls', outcome: 'pending', verified_at: Time.current
    )
  end
  let(:incoming_service) { instance_double(Whatsapp::IncomingCallService, perform: true) }

  before do
    account.enable_features!('channel_voice')
    channel.update!(provider_config: channel.provider_config.merge('calling_enabled' => true))
    allow(Whatsapp::IncomingCallService).to receive(:new).and_return(incoming_service)
  end

  it 'decrypts a claimed voice payload and marks its ledger event applied' do
    described_class.perform_now({}, event.id, Lla::Voice::PayloadCipher.encrypt(payload))

    expect(incoming_service).to have_received(:perform)
    expect(event.reload.outcome).to eq('applied')
  end

  it 'marks the ledger event rejected when voice processing fails' do
    allow(incoming_service).to receive(:perform).and_raise(ArgumentError, 'invalid provider event')

    expect do
      described_class.perform_now({}, event.id, Lla::Voice::PayloadCipher.encrypt(payload))
    end.to raise_error(ArgumentError, 'invalid provider event')
    expect(event.reload.outcome).to eq('rejected')
  end
end
