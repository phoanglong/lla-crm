# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Captain::QuotaManager, type: :model do
  let(:account) { create(:account, limits: { captain_responses: 2 }) }

  def manager(key: 'request-1', owner: 'worker-1', target_account: account, now: Time.current)
    described_class.new(
      account: target_account,
      idempotency_key: key,
      owner_token: owner,
      feature: 'editor',
      provider: 'openai',
      credential_source: 'system',
      reason: 'spec',
      now: now
    )
  end

  it 'reserves then consumes exactly one unit and updates account availability' do
    quota = manager

    expect(quota.reserve!).to be_acquired
    expect(quota.consume!).to be true

    ledger = account.lla_captain_quota_ledgers.sole
    expect(ledger).to have_attributes(reserved_units: 0, consumed_units: 1, released_units: 0)
    expect(account.reload.usage_limits.dig(:captain, :responses)).to include(consumed: 1, current_available: 1)
  end

  it 'releases a failed reservation without consuming quota' do
    quota = manager
    quota.reserve!

    expect(quota.release!).to be true
    expect(quota.release!).to be true

    ledger = account.lla_captain_quota_ledgers.sole
    expect(ledger).to have_attributes(reserved_units: 0, consumed_units: 0, released_units: 1)
  end

  it 'rejects before work when the plan is exhausted' do
    first = manager(key: 'first')
    second = manager(key: 'second')
    third = manager(key: 'third')
    first.reserve!
    second.reserve!

    result = third.reserve!

    expect(result).to be_rejected
    expect(result.reservation).to be_rejected
    expect(account.lla_captain_quota_ledgers.sole.reserved_units).to eq(2)
  end

  it 'does not let a different owner execute the same in-flight key' do
    expect(manager.reserve!).to be_acquired

    duplicate = manager(owner: 'worker-2').reserve!

    expect(duplicate).to be_duplicate
    expect(duplicate.status).to eq(:duplicate_in_flight)
  end

  it 'returns a terminal duplicate instead of charging an already consumed key again' do
    first = manager
    first.reserve!
    first.consume!

    duplicate = manager(owner: 'worker-2').reserve!

    expect(duplicate.status).to eq(:duplicate_consumed)
    expect(account.lla_captain_quota_ledgers.sole.consumed_units).to eq(1)
  end

  it 'allows the same caller key in a different account without collision' do
    other_account = create(:account, limits: { captain_responses: 1 })

    expect(manager.reserve!).to be_acquired
    expect(manager(target_account: other_account).reserve!).to be_acquired
    expect(Lla::Captain::QuotaReservation.count).to eq(2)
  end

  it 'reclaims an abandoned reservation after the bounded claim TTL' do
    started_at = Time.utc(2026, 8, 16, 1, 0, 0)
    manager(now: started_at).reserve!

    reclaimed = manager(owner: 'worker-2', now: started_at + described_class::CLAIM_TTL + 1.second).reserve!

    expect(reclaimed).to be_acquired
    expect(reclaimed.reservation.reload.attempts).to eq(2)
  end

  it 'detects and repairs counter drift from the immutable reservation rows' do
    quota = manager
    quota.reserve!
    ledger = account.lla_captain_quota_ledgers.sole
    ledger.update_columns(reserved_units: 2) # rubocop:disable Rails/SkipsModelValidations

    expect(quota.reconcile!).to include(drift: true, repaired: false)
    expect(ledger.reload).to be_reconciliation_drifted

    expect(quota.reconcile!(repair: true)).to include(drift: true, repaired: true)
    expect(ledger.reload).to have_attributes(reserved_units: 1, reconciliation_state: 'verified')
  end

  it 'never stores the raw idempotency key or owner token' do
    raw_key = 'secret-looking-request-key'
    raw_owner = 'worker-token-value'
    reservation = manager(key: raw_key, owner: raw_owner).reserve!.reservation

    expect(reservation.idempotency_key_digest).not_to include(raw_key)
    expect(reservation.owner_token_digest).not_to include(raw_owner)
    expect(reservation.attributes.to_json).not_to include(raw_key, raw_owner)
  end
end
