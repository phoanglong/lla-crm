# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::OwnershipChallenge do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:other_portal) { create(:portal, account: create(:account)) }
  let(:domain) do
    Lla::CustomDomains::Domain.create!(account_id: account.id, portal_id: portal.id,
                                       hostname: 'docs.example.com', state: 'requested')
  end

  it 'stores only a hostname-bound digest and an encrypted proof' do
    issued = described_class.issue!(domain)
    domain.reload

    expect(domain.challenge_id_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(domain.challenge_id_digest).not_to include(issued.id)
    expect(domain.challenge_ciphertext).not_to include(issued.body)
    expect(domain.attributes.values.map(&:to_s).join(' ')).not_to include(issued.body)
  end

  it 'resolves only the exact live challenge id' do
    issued = described_class.issue!(domain)

    expect(described_class.resolve(domain, issued.id)).to eq(issued.body)
    expect(described_class.resolve(domain, "#{issued.id}x")).to be_nil
    expect(described_class.resolve(domain, issued.id.reverse)).to be_nil
    expect(described_class.resolve(domain, '')).to be_nil
  end

  it 'stops resolving once expired' do
    issued = described_class.issue!(domain)

    expect(described_class.resolve(domain, issued.id, now: described_class::TTL.from_now + 1.second)).to be_nil
  end

  it 'stops resolving once revoked' do
    issued = described_class.issue!(domain)
    described_class.revoke!(domain)

    expect(described_class.resolve(domain.reload, issued.id)).to be_nil
    expect(described_class.probe_path(domain)).to be_nil
  end

  it 'refuses a challenge minted for another host' do
    issued = described_class.issue!(domain)
    foreign = Lla::CustomDomains::Domain.create!(account_id: other_portal.account_id, portal_id: other_portal.id,
                                                 hostname: 'help.example.com', state: 'requested')
    foreign.update_columns(challenge_id_digest: domain.reload.challenge_id_digest, # rubocop:disable Rails/SkipsModelValidations
                           challenge_ciphertext: domain.challenge_ciphertext,
                           challenge_expires_at: domain.challenge_expires_at)

    expect(described_class.resolve(foreign, issued.id)).to be_nil
  end

  it 'rotates within a bounded budget and invalidates the previous nonce' do
    first = described_class.issue!(domain)
    second = described_class.rotate!(domain)

    expect(described_class.resolve(domain.reload, first.id)).to be_nil
    expect(described_class.resolve(domain, second.id)).to eq(second.body)

    domain.update!(challenge_rotations: Lla::CustomDomains::Domain::MAX_CHALLENGE_ROTATIONS)
    expect { described_class.rotate!(domain) }.to raise_error(described_class::RotationExhausted)
  end

  it 'exposes a probe path only while the challenge is live' do
    issued = described_class.issue!(domain)

    expect(described_class.probe_path(domain)).to eq("#{described_class::CHALLENGE_PATH_PREFIX}#{issued.id}")
    expect(described_class.probe_path(domain, now: described_class::TTL.from_now + 1.second)).to be_nil
  end
end
