require 'rails_helper'

RSpec.describe Lla::CustomDomains::ChallengeResolver do
  let(:portal) do
    create(
      :portal,
      custom_domain: 'docs.example.com',
      ssl_settings: {
        'cf_verification_id' => 'challenge-123',
        'cf_verification_body' => 'proof-body',
        'cf_verification_expires_at' => 10.minutes.from_now.iso8601
      }
    )
  end

  before { portal }

  it 'returns the proof only for the exact active host, token, and expiry' do
    expect(described_class.resolve(host: 'DOCS.EXAMPLE.COM.', challenge_id: 'challenge-123')).to eq('proof-body')
  end

  it 'does not disclose proof for a wrong host or token' do
    expect(described_class.resolve(host: 'other.example.com', challenge_id: 'challenge-123')).to be_nil
    expect(described_class.resolve(host: 'docs.example.com', challenge_id: 'wrong')).to be_nil
  end

  it 'does not disclose expired or archived portal challenges' do
    portal.update!(ssl_settings: portal.ssl_settings.merge('cf_verification_expires_at' => 1.minute.ago.iso8601))
    expect(described_class.resolve(host: portal.custom_domain, challenge_id: 'challenge-123')).to be_nil

    portal.update!(archived: true, ssl_settings: portal.ssl_settings.merge('cf_verification_expires_at' => 1.minute.from_now.iso8601))
    expect(described_class.resolve(host: portal.custom_domain, challenge_id: 'challenge-123')).to be_nil
  end
end
