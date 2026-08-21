# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Captain::QuotaReconciliationService, type: :service do
  let(:account) { create(:account, limits: { captain_responses: 3 }) }

  def manager(key:, owner:, now: Time.current)
    Lla::Captain::QuotaManager.new(
      account: account,
      idempotency_key: key,
      owner_token: owner,
      feature: 'assistant',
      provider: 'openai',
      credential_source: 'system',
      reason: 'reconciliation_spec',
      now: now
    )
  end

  it 'releases stale reservations and repairs ledger counters from reservation rows' do
    stale_at = 2.hours.ago
    manager(key: 'stale', owner: 'worker-1', now: stale_at).reserve!
    fresh = manager(key: 'fresh', owner: 'worker-2')
    fresh.reserve!
    fresh.consume!
    ledger = account.lla_captain_quota_ledgers.sole
    ledger.update_columns(reserved_units: 99, consumed_units: 99) # rubocop:disable Rails/SkipsModelValidations

    result = described_class.new(ledger).perform

    expect(result).to include(released_units: 1, drift: true)
    expect(ledger.reload).to have_attributes(
      reserved_units: 0,
      consumed_units: 1,
      released_units: 1,
      reconciliation_state: 'verified'
    )
    expect(ledger.reservations.find_by!(reason: 'reconciliation_spec', state: :released)).to be_released
  end

  it 'preserves a fresh in-flight reservation' do
    manager(key: 'fresh', owner: 'worker').reserve!
    ledger = account.lla_captain_quota_ledgers.sole

    result = described_class.new(ledger).perform

    expect(result).to include(released_units: 0, drift: false)
    expect(ledger.reload).to have_attributes(reserved_units: 1, reconciliation_state: 'verified')
  end
end
