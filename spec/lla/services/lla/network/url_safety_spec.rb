require 'rails_helper'

RSpec.describe Lla::Network::UrlSafety do
  describe '.validate!' do
    it 'accepts a public http URL and returns the pinned address' do
      allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34'])

      result = described_class.validate!('https://example.com/path')

      expect(result.uri.to_s).to eq('https://example.com/path')
      expect(result.ip_address).to eq('93.184.216.34')
    end

    it 'rejects loopback and private DNS results' do
      allow(Resolv).to receive(:getaddresses).with('internal.example').and_return(['127.0.0.1'])

      expect { described_class.validate!('https://internal.example') }
        .to raise_error(described_class::UnsafeUrlError, 'host resolves to a non-public address')
    end

    it 'rejects URL credentials' do
      expect { described_class.validate!('https://user:pass@example.com') }
        .to raise_error(described_class::UnsafeUrlError, 'URL credentials are not allowed')
    end
  end
end
