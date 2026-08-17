# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::HostCanonicalizer do
  describe '.call' do
    it 'lowercases, drops the trailing dot and keeps a DNS-safe host' do
      expect(described_class.call('  Docs.Example.COM.'.strip)).to eq('docs.example.com')
    end

    it 'converts a unicode host to its IDNA form' do
      expect(described_class.call('bücher.example.com')).to eq('xn--bcher-kva.example.com')
    end

    it 'rejects a host carrying a scheme or port' do
      expect { described_class.call('https://docs.example.com') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_scheme_or_port_not_allowed')
      expect { described_class.call('docs.example.com:8443') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_scheme_or_port_not_allowed')
    end

    it 'rejects userinfo and path segments' do
      expect { described_class.call('admin@docs.example.com') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_userinfo_not_allowed')
      expect { described_class.call('docs.example.com/admin') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_path_not_allowed')
    end

    it 'rejects CRLF, tabs and unicode separators smuggled into the host' do
      ["docs.example.com\r\nX-Injected: 1", "docs.example.com\t", 'docs .example.com', 'docs.example.com​'].each do |value|
        expect { described_class.call(value) }
          .to raise_error(described_class::InvalidHost, 'lla_custom_domain_control_character')
      end
    end

    it 'rejects a mixed-script confusable label' do
      expect { described_class.call('аpple.example.com') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_confusable_host')
    end

    it 'rejects IP literals, reserved suffixes and single labels' do
      expect { described_class.call('127.0.0.1') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_ip_literal_not_allowed')
      expect { described_class.call('helpdesk.localhost') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_reserved_suffix')
      expect { described_class.call('localhost') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_invalid_label')
    end

    it 'rejects malformed labels and empty input' do
      expect { described_class.call('docs..example.com') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_invalid_label')
      expect { described_class.call('-docs.example.com') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_invalid_label')
      expect { described_class.call('  ') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_blank_host')
    end

    it 'rejects a host longer than the DNS limit' do
      expect { described_class.call("#{(['a' * 60] * 5).join('.')}.example.com") }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_host_too_long')
    end
  end

  describe '.from_user_input' do
    it 'accepts a pasted portal URL but nothing more than the bare host' do
      expect(described_class.from_user_input(' https://Support.Example.dev/ ')).to eq('support.example.dev')
      expect(described_class.from_user_input('http://docs.example.com')).to eq('docs.example.com')
    end

    it 'still rejects a real path, port or userinfo behind the scheme' do
      expect { described_class.from_user_input('https://docs.example.com/admin') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_path_not_allowed')
      expect { described_class.from_user_input('https://docs.example.com:8443') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_scheme_or_port_not_allowed')
      expect { described_class.from_user_input('https://admin@docs.example.com') }
        .to raise_error(described_class::InvalidHost, 'lla_custom_domain_userinfo_not_allowed')
    end
  end

  describe '.canonicalize' do
    it 'returns nil instead of raising for read paths' do
      expect(described_class.canonicalize('docs.example.com/../etc')).to be_nil
      expect(described_class.canonicalize('docs.example.com')).to eq('docs.example.com')
    end
  end
end
