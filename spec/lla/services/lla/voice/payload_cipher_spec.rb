# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Voice::PayloadCipher do
  it 'round-trips a payload without exposing its plaintext in the token' do
    payload = { entry: [{ calls: [{ from: '15550001111', session: { sdp: 'v=0 secret-sdp' } }] }] }

    token = described_class.encrypt(payload)

    expect(token).not_to include('15550001111', 'secret-sdp')
    expect(described_class.decrypt(token)).to eq(payload)
  end

  it 'rejects a modified token' do
    token = described_class.encrypt(secret: 'value')

    expect { described_class.decrypt("#{token}tampered") }
      .to raise_error(ArgumentError, 'Invalid encrypted voice payload')
  end
end
