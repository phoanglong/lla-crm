# frozen_string_literal: true

class Lla::Captain::QuotaReconciliationService
  STALE_AFTER = 1.hour

  def initialize(ledger, now: Time.current)
    @ledger = ledger
    @now = now
  end

  def perform
    ledger.with_lock do
      released_units = release_stale_reservations!
      expected = reservation_totals
      drift = ledger_counters(expected).any? { |column, value| ledger.public_send(column) != value }
      ledger.update!(
        expected.merge(
          reconciliation_state: :verified,
          last_reconciled_at: now,
          metadata: reconciliation_metadata(released_units, drift)
        )
      )
      instrument(released_units, drift)
      { released_units: released_units, drift: drift, expected: expected }
    end
  end

  private

  attr_reader :ledger, :now

  # This is an administrative recovery transition. The ledger lock and state
  # predicate make it safe without possessing an expired worker owner token.
  # rubocop:disable Rails/SkipsModelValidations
  def release_stale_reservations!
    scope = ledger.reservations.reserved.where('claimed_at < ?', STALE_AFTER.ago(now))
    units = scope.sum(:units)
    scope.update_all(state: Lla::Captain::QuotaReservation.states.fetch(:released), released_at: now, updated_at: now)
    units
  end
  # rubocop:enable Rails/SkipsModelValidations

  def reservation_totals
    totals = ledger.reservations.group(:state).sum(:units)
    {
      reserved_units: totals.fetch('reserved', 0),
      consumed_units: totals.fetch('consumed', 0),
      released_units: totals.fetch('released', 0)
    }
  end

  def ledger_counters(expected)
    expected.slice(:reserved_units, :consumed_units, :released_units)
  end

  def reconciliation_metadata(released_units, drift)
    ledger.metadata.merge(
      'last_reconciliation' => {
        'version' => 1,
        'released_stale_units' => released_units,
        'drift_repaired' => drift,
        'at' => now.utc.iso8601
      }
    )
  end

  def instrument(released_units, drift)
    ActiveSupport::Notifications.instrument(
      'lla.captain.quota.reconciled',
      account_id: ledger.account_id,
      ledger_id: ledger.id,
      released_stale_units: released_units,
      drift_repaired: drift
    )
  end
end
