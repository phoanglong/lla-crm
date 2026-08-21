# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::ChallengeResolver do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:domain) { Lla::CustomDomains::LifecycleService.new(portal: portal).request!('docs.example.com') }

  it 'returns the proof for the exact canonical host and live challenge id' do
    challenge = Lla::CustomDomains::OwnershipChallenge.issue!(domain)

    expect(described_class.resolve(host: 'DOCS.EXAMPLE.COM.', challenge_id: challenge.id)).to eq(challenge.body)
  end

  it 'returns nothing for another host, another id or an expired challenge' do
    challenge = Lla::CustomDomains::OwnershipChallenge.issue!(domain)

    expect(described_class.resolve(host: 'help.example.com', challenge_id: challenge.id)).to be_nil
    expect(described_class.resolve(host: 'docs.example.com', challenge_id: 'not-the-nonce')).to be_nil
    expect(
      described_class.resolve(host: 'docs.example.com', challenge_id: challenge.id,
                              now: Lla::CustomDomains::OwnershipChallenge::TTL.from_now + 1.second)
    ).to be_nil
  end

  it 'returns nothing for a malformed or hostile Host header' do
    challenge = Lla::CustomDomains::OwnershipChallenge.issue!(domain)

    ["docs.example.com\r\nX-Injected: 1", 'docs.example.com:8443', 'docs.example.com/admin', ''].each do |host|
      expect(described_class.resolve(host: host, challenge_id: challenge.id)).to be_nil
    end
  end

  it 'stops serving the challenge once the domain leaves ownership_pending' do
    challenge = Lla::CustomDomains::OwnershipChallenge.issue!(domain)
    domain.update!(state: 'provisioning', ownership_verified_at: Time.current)

    expect(described_class.resolve(host: 'docs.example.com', challenge_id: challenge.id)).to be_nil
  end
end
