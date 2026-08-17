require 'rails_helper'

RSpec.describe Lla::Knowledge::UrlPolicy do
  it 'canonicalizes safe absolute URLs and removes fragments' do
    expect(described_class.canonicalize(' HTTPS://Docs.Example.COM./guide?q=1#section '))
      .to eq('https://docs.example.com/guide?q=1')
  end

  it 'rejects credentials, non-HTTP schemes, non-default ports, and Unicode hosts' do
    invalid_urls = [
      'https://user:pass@example.com/',
      'file:///etc/passwd',
      'https://example.com:8443/',
      'https://exämple.com/'
    ]

    invalid_urls.each do |url|
      expect { described_class.canonicalize(url) }.to raise_error(described_class::InvalidUrl)
    end
  end

  it 'only approves canonical links on the original origin' do
    expect(described_class.approved_same_origin?('https://docs.example.com/', 'https://docs.example.com/a')).to be(true)
    expect(described_class.approved_same_origin?('https://docs.example.com/', 'https://evil.example/a')).to be(false)
  end
end
