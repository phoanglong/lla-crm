# frozen_string_literal: true

require 'digest'

class Lla::Captain::QuotaManager
  Result = Struct.new(:reservation, :status, keyword_init: true) do
    def acquired? = status == :acquired
    def rejected? = status == :rejected
    def duplicate? = status.to_s.start_with?('duplicate_')
  end

  CLAIM_TTL = 15.minutes
  MAX_KEY_BYTES = 200
  MAX_UNITS = 100

  attr_reader :account, :feature, :provider, :credential_source, :reason, :units

  # rubocop:disable Metrics/ParameterLists
  def initialize(account:, idempotency_key:, owner_token:, feature:, provider:, credential_source:, reason:, units: 1,
                 now: Time.current)
    @account = account
    @idempotency_key = bounded_value!(idempotency_key, 'idempotency_key')
    @owner_token = bounded_value!(owner_token, 'owner_token')
    @feature = bounded_value!(feature, 'feature', maximum: 128)
    @provider = bounded_value!(provider, 'provider', maximum: 64)
    @credential_source = bounded_value!(credential_source, 'credential_source', maximum: 32)
    @reason = bounded_value!(reason, 'reason', maximum: 128)
    @units = Integer(units)
    @now = now
    raise ArgumentError, 'units is outside the supported range' unless @units.between?(1, MAX_UNITS)
  end
  # rubocop:enable Metrics/ParameterLists

  def reserve!
    existing = reservation
    return existing_result(existing) if existing

    ledger = current_ledger
    ledger.with_lock { reserve_from_locked_ledger(ledger) }
  rescue ActiveRecord::RecordNotUnique
    existing_result(reservation || raise)
  end

  def consume!
    transition!(:consumed)
  end

  def release!
    transition!(:released)
  end

  def reconcile!(repair: false)
    ledger = current_ledger
    ledger.with_lock do
      totals = ledger.reservations.group(:state).sum(:units)
      expected = {
        reserved_units: totals.fetch('reserved', 0),
        consumed_units: totals.fetch('consumed', 0),
        released_units: totals.fetch('released', 0)
      }
      drift = expected.any? { |column, value| ledger.public_send(column) != value }
      attributes = { last_reconciled_at: @now, reconciliation_state: drift ? :drifted : :verified }
      attributes.merge!(expected)[:reconciliation_state] = :verified if drift && repair
      ledger.update!(attributes)
      notify(:reconciled, nil, drift: drift, repaired: drift && repair)
      { drift: drift, repaired: drift && repair, expected: expected }
    end
  end

  def reservation
    Lla::Captain::QuotaReservation.find_by(idempotency_key_digest: idempotency_digest)
  end

  private

  def current_ledger
    period_start = @now.utc.beginning_of_month
    period_end = period_start.next_month
    Lla::Captain::QuotaLedger.create_or_find_by!(account: account, bucket: Lla::Captain::QuotaLedger::BUCKET, period_start: period_start) do |ledger|
      ledger.period_end = period_end
      ledger.limit_snapshot = current_limit
      ledger.opening_consumed_units = legacy_opening_balance
    end
  end

  def current_limit
    @current_limit ||= account.captain_monthly_limit[:responses].to_i.clamp(0, ChatwootApp.max_limit)
  end

  def legacy_opening_balance
    account.custom_attributes[Lla::Account::PlanUsageAndLimits::CAPTAIN_RESPONSES_USAGE].to_i.clamp(0, ChatwootApp.max_limit)
  end

  def reservation_attributes
    {
      idempotency_key_digest: idempotency_digest,
      owner_token_digest: owner_digest,
      feature: feature,
      provider: provider,
      credential_source: credential_source,
      reason: reason,
      state: :reserved,
      units: units,
      attempts: 1,
      claimed_at: @now
    }
  end

  def reserve_from_locked_ledger(ledger)
    existing = reservation
    return existing_result(existing) if existing

    ledger.update!(limit_snapshot: current_limit) if ledger.limit_snapshot != current_limit
    return reject!(ledger) if ledger.available_units < units

    created = ledger.reservations.create!(reservation_attributes)
    ledger.update!(reserved_units: ledger.reserved_units + units, reconciliation_state: :pending)
    notify(:reserved, created)
    Result.new(reservation: created, status: :acquired)
  end

  def reject!(ledger)
    rejected = ledger.reservations.create!(reservation_attributes.merge(
                                             state: :rejected,
                                             owner_token_digest: nil,
                                             claimed_at: nil,
                                             rejection_code: 'quota_exhausted'
                                           ))
    notify(:rejected, rejected)
    Result.new(reservation: rejected, status: :rejected)
  end

  def existing_result(existing)
    return Result.new(reservation: existing, status: :rejected) if existing.rejected?
    return Result.new(reservation: existing, status: :duplicate_consumed) if existing.consumed?
    return Result.new(reservation: existing, status: :duplicate_released) if existing.released?
    return Result.new(reservation: existing, status: :acquired) if secure_owner?(existing)

    existing.with_lock do
      if existing.reserved? && existing.claimed_at < CLAIM_TTL.ago(@now)
        existing.update!(owner_token_digest: owner_digest, claimed_at: @now, attempts: existing.attempts + 1)
        notify(:reclaimed, existing)
        Result.new(reservation: existing, status: :acquired)
      else
        Result.new(reservation: existing, status: :duplicate_in_flight)
      end
    end
  end

  def transition!(target)
    existing = reservation
    return false unless existing
    return true if existing.public_send("#{target}?")
    return false unless existing.reserved? && secure_owner?(existing)

    ledger = existing.quota_ledger
    ledger.with_lock { transition_locked!(existing, ledger, target) }
  end

  def transition_locked!(existing, ledger, target)
    existing.lock!
    return true if existing.public_send("#{target}?")
    return false if !existing.reserved? || !secure_owner?(existing)

    timestamp_column = target == :consumed ? :consumed_at : :released_at
    counter_column = target == :consumed ? :consumed_units : :released_units
    attributes = {
      reserved_units: [ledger.reserved_units - existing.units, 0].max,
      reconciliation_state: :pending
    }
    attributes[counter_column] = ledger.public_send(counter_column) + existing.units
    ledger.update!(attributes)
    existing.update!({ state: target }.merge(timestamp_column => @now))
    notify(target, existing)
    true
  end

  def idempotency_digest
    @idempotency_digest ||= Digest::SHA256.hexdigest("#{account.id}\0#{@idempotency_key}")
  end

  def owner_digest
    @owner_digest ||= Digest::SHA256.hexdigest("#{account.id}\0#{@owner_token}")
  end

  def secure_owner?(reservation)
    stored = reservation.owner_token_digest.to_s
    stored.bytesize == owner_digest.bytesize && ActiveSupport::SecurityUtils.secure_compare(stored, owner_digest)
  end

  def bounded_value!(value, name, maximum: MAX_KEY_BYTES)
    candidate = value.to_s
    raise ArgumentError, "#{name} is required" if candidate.blank?
    raise ArgumentError, "#{name} is too long" if candidate.bytesize > maximum

    candidate
  end

  def notify(action, reservation, extra = {})
    ActiveSupport::Notifications.instrument(
      "lla.captain.quota.#{action}",
      {
        account_id: account.id,
        ledger_id: reservation&.quota_ledger_id || current_ledger.id,
        reservation_id: reservation&.id,
        feature: feature,
        provider: provider,
        credential_source: credential_source,
        units: units
      }.merge(extra)
    )
  end
end
