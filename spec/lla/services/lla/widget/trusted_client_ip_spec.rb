# frozen_string_literal: true

require 'rails_helper'

# Deterministic boundary spec for the trusted client-IP resolution. Runs identically
# under EE ON and DISABLE_ENTERPRISE=true and needs no request/Vite rendering.
RSpec.describe Lla::Widget::TrustedClientIp do
  describe '.resolve' do
    it 'ignores a spoofed forwarded IP when the direct peer is not a trusted proxy' do
      resolved = described_class.resolve(remote_ip: '8.8.8.8', remote_addr: '203.0.113.9')
      expect(resolved).to eq('203.0.113.9')
    end

    it 'honours the forwarded IP only when the direct peer is a trusted proxy' do
      resolved = described_class.resolve(remote_ip: '8.8.4.4', remote_addr: '127.0.0.1')
      expect(resolved).to eq('8.8.4.4')
    end

    it 'falls back to the direct address when the peer address is malformed' do
      resolved = described_class.resolve(remote_ip: '8.8.8.8', remote_addr: 'not-an-ip')
      expect(resolved).to eq('not-an-ip')
    end

    it 'falls back to the direct address when the peer address is blank' do
      resolved = described_class.resolve(remote_ip: '8.8.8.8', remote_addr: '')
      expect(resolved).to eq('')
    end
  end
end
