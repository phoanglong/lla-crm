# frozen_string_literal: true

class CreateLlaCaptainQuotaLedger < ActiveRecord::Migration[7.1]
  # rubocop:disable Metrics/MethodLength
  def up
    create_quota_ledgers
    create_quota_reservations
    backfill_opening_balances
  end

  def down
    drop_table :lla_captain_quota_reservations
    drop_table :lla_captain_quota_ledgers
  end

  private

  def create_quota_ledgers
    create_table :lla_captain_quota_ledgers do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.string :bucket, null: false, default: 'captain_responses', limit: 64
      t.datetime :period_start, null: false
      t.datetime :period_end, null: false
      t.bigint :limit_snapshot, null: false, default: 0
      t.bigint :opening_consumed_units, null: false, default: 0
      t.bigint :reserved_units, null: false, default: 0
      t.bigint :consumed_units, null: false, default: 0
      t.bigint :released_units, null: false, default: 0
      t.integer :reconciliation_state, null: false, default: 0
      t.datetime :last_reconciled_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :lla_captain_quota_ledgers, %i[account_id bucket period_start],
              unique: true, name: 'idx_lla_quota_ledgers_account_bucket_period'
    add_check_constraint :lla_captain_quota_ledgers, 'period_end > period_start',
                         name: 'lla_quota_ledgers_valid_period'
    add_check_constraint :lla_captain_quota_ledgers,
                         'limit_snapshot >= 0 AND opening_consumed_units >= 0 AND reserved_units >= 0 ' \
                         'AND consumed_units >= 0 AND released_units >= 0',
                         name: 'lla_quota_ledgers_non_negative'
    add_check_constraint :lla_captain_quota_ledgers, 'reconciliation_state IN (0, 1, 2)',
                         name: 'lla_quota_ledgers_reconciliation_state'
  end

  def create_quota_reservations
    create_table :lla_captain_quota_reservations do |t|
      t.references :quota_ledger, null: false, foreign_key: { to_table: :lla_captain_quota_ledgers, on_delete: :cascade },
                                  index: false
      t.string :idempotency_key_digest, null: false, limit: 64
      t.string :owner_token_digest, limit: 64
      t.string :feature, null: false, limit: 128
      t.string :provider, null: false, limit: 64
      t.string :credential_source, null: false, limit: 32
      t.string :reason, null: false, limit: 128
      t.integer :state, null: false, default: 0
      t.integer :units, null: false, default: 1
      t.integer :attempts, null: false, default: 1
      t.string :rejection_code, limit: 64
      t.string :request_fingerprint, limit: 64
      t.datetime :claimed_at
      t.datetime :consumed_at
      t.datetime :released_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :lla_captain_quota_reservations, :idempotency_key_digest,
              unique: true, name: 'idx_lla_quota_reservations_idempotency'
    add_index :lla_captain_quota_reservations, %i[quota_ledger_id state],
              name: 'idx_lla_quota_reservations_ledger_state'
    add_index :lla_captain_quota_reservations, %i[state claimed_at],
              name: 'idx_lla_quota_reservations_stale_claims'
    add_check_constraint :lla_captain_quota_reservations, 'state IN (0, 1, 2, 3)',
                         name: 'lla_quota_reservations_state'
    add_check_constraint :lla_captain_quota_reservations, 'units > 0 AND attempts > 0',
                         name: 'lla_quota_reservations_positive_values'
    add_check_constraint :lla_captain_quota_reservations,
                         '(state = 0 AND owner_token_digest IS NOT NULL AND claimed_at IS NOT NULL) OR state <> 0',
                         name: 'lla_quota_reservations_claimed_when_reserved'
  end

  def backfill_opening_balances
    execute <<~SQL.squish
      INSERT INTO lla_captain_quota_ledgers
        (account_id, bucket, period_start, period_end, limit_snapshot,
         opening_consumed_units, reserved_units, consumed_units, released_units,
         reconciliation_state, metadata, created_at, updated_at)
      SELECT
        accounts.id,
        'captain_responses',
        date_trunc('month', CURRENT_TIMESTAMP),
        date_trunc('month', CURRENT_TIMESTAMP) + interval '1 month',
        legacy_usage.value,
        legacy_usage.value,
        0,
        0,
        0,
        0,
        '{"source":"captain_responses_usage_backfill","version":1}'::jsonb,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM accounts
      CROSS JOIN LATERAL (
        SELECT CASE
          WHEN COALESCE(accounts.custom_attributes ->> 'captain_responses_usage', '') ~ '^[0-9]+$'
            THEN LEAST(
              (accounts.custom_attributes ->> 'captain_responses_usage')::numeric,
              9223372036854775807::numeric
            )::bigint
          ELSE 0
        END AS value
      ) AS legacy_usage
      WHERE legacy_usage.value > 0
      ON CONFLICT (account_id, bucket, period_start) DO NOTHING
    SQL
  end
  # rubocop:enable Metrics/MethodLength
end
