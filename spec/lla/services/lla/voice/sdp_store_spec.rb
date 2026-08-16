# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Voice::SdpStore do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_whatsapp, account: account, validate_provider_config: false, sync_templates: false) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:call) do
    create(:call, account: account, inbox: channel.inbox, conversation: conversation, contact: conversation.contact,
                  provider: :whatsapp, provider_call_id: 'wacid-sdp-store', status: 'ringing')
  end
  let(:sdp) { "v=0\r\no=lla 1 1 IN IP4 127.0.0.1\r\n" }

  after { described_class.delete(call: call) }

  it 'stores encrypted SDP with a digest and reads it back' do
    digest = described_class.write(call: call, kind: 'offer', sdp: sdp)
    redis_key = "LLA_VOICE_SDP::#{account.id}:#{call.id}:offer"

    expect(digest).to eq(Digest::SHA256.hexdigest(sdp))
    expect(Redis::Alfred.get(redis_key)).not_to include(sdp)
    expect(described_class.read(call: call, kind: 'offer')).to eq(sdp)
  end

  it 'rejects malformed and oversized SDP' do
    expect { described_class.validate!('offer', 'not-sdp') }.to raise_error(ArgumentError, 'Invalid SDP')
    expect { described_class.validate!('offer', "v=#{'x' * described_class::MAX_BYTES}") }
      .to raise_error(ArgumentError, 'SDP is too large')
  end

  it 'deletes both offer and answer material' do
    described_class.write(call: call, kind: 'offer', sdp: sdp)
    described_class.write(call: call, kind: 'answer', sdp: sdp)

    described_class.delete(call: call)

    expect(described_class.read(call: call, kind: 'offer')).to be_nil
    expect(described_class.read(call: call, kind: 'answer')).to be_nil
  end
end
