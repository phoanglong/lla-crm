require 'rails_helper'

RSpec.describe Lla::Knowledge::GenerationOperation do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:digest) { Digest::SHA256.hexdigest('operation') }

  def build_operation(overrides = {})
    described_class.new(
      {
        account: account,
        portal: portal,
        user: user,
        idempotency_digest: digest,
        request_digest: Digest::SHA256.hexdigest('request')
      }.merge(overrides)
    )
  end

  it 'accepts a tenant-bound operation and assigns bounded retention' do
    operation = build_operation

    expect(operation).to be_valid
    expect(operation.expires_at).to be_within(2.seconds).of(30.days.from_now)
  end

  it 'rejects a portal from another tenant' do
    operation = build_operation(portal: create(:portal, account: create(:account)))

    expect(operation).not_to be_valid
    expect(operation.errors[:portal]).to include('must belong to the operation account')
  end

  it 'rejects a user without membership in the operation tenant' do
    operation = build_operation(user: create(:user, account: create(:account)))

    expect(operation).not_to be_valid
    expect(operation.errors[:user]).to include('must be a member of the operation account')
  end

  it 'rejects counters that can overrun the expected item count' do
    operation = build_operation(expected_items: 1, finished_items: 2, failed_items: 0)

    expect(operation).not_to be_valid
    expect(operation.errors[:base]).to include('operation counts are inconsistent')
  end

  it 'identifies every monotonic terminal state' do
    operation = build_operation

    expect(described_class::TERMINAL_STATES).to all(satisfy do |state|
      operation.state = state
      operation.terminal?
    end)
  end
end
