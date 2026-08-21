require 'rails_helper'

RSpec.describe Portal do
  let(:account) { create(:account) }
  let(:digest) { Digest::SHA256.hexdigest('onboarding-portal') }

  it 'rejects malformed identity digests at the database boundary' do
    portal = create(:portal, account: account)

    expect do
      described_class.transaction(requires_new: true) do
        portal.lla_onboarding_key_digest = 'not-a-digest'
        portal.save!(validate: false)
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_lla_portals_onboarding_digest/)
  end

  it 'prevents duplicate onboarding identities inside one tenant' do
    create(:portal, account: account, lla_onboarding_key_digest: digest)
    duplicate = create(:portal, account: account)

    expect do
      described_class.transaction(requires_new: true) do
        duplicate.lla_onboarding_key_digest = digest
        duplicate.save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows the same deterministic digest in another tenant' do
    create(:portal, account: account, lla_onboarding_key_digest: digest)
    other_account = create(:account)

    expect do
      create(:portal, account: other_account, lla_onboarding_key_digest: digest)
    end.to change(described_class, :count).by(1)
  end
end
