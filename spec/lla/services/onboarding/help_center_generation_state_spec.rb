require 'rails_helper'

RSpec.describe Onboarding::HelpCenterGenerationState do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('facade-operation'),
      request_digest: Digest::SHA256.hexdigest('facade-request')
    )
  end

  it 'returns durable status only through the owning account' do
    expect(described_class.current(operation.id, account: account)).to include(
      'status' => 'generating', 'total' => 0, 'finished' => 0, 'errors' => 0
    )
    expect(described_class.current(operation.id, account: create(:account))).to be_nil
  end

  it 'records a stable skip reason without storing raw exception text' do
    described_class.skip(operation.id, account: account, reason: 'Provider said secret=abc!')

    expect(operation.reload).to have_attributes(state: 'skipped', last_error_code: 'generation_skipped')
  end
end
