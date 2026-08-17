# frozen_string_literal: true

class CreateLlaCustomDomainLifecycle < ActiveRecord::Migration[7.1]
  HOSTNAME_SQL = 'hostname = lower(hostname) AND char_length(hostname) BETWEEN 4 AND 253 AND ' \
                 "hostname ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'"

  def up
    create_custom_domains
    create_custom_domain_operations
    backfill_custom_domains
    scrub_legacy_ssl_settings
  end

  def down
    drop_table :lla_custom_domain_operations, if_exists: true
    drop_table :lla_custom_domains, if_exists: true
  end

  private

  def create_custom_domains # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    create_table :lla_custom_domains do |t|
      t.bigint :account_id, null: false
      t.bigint :portal_id, null: false
      t.string :hostname, null: false, limit: 253
      t.string :state, null: false, default: 'requested', limit: 32
      t.integer :version, null: false, default: 1
      t.string :provider, null: false, default: 'none', limit: 32
      t.string :provider_resource_id, limit: 128
      t.string :provider_status, limit: 64
      t.datetime :provider_synced_at
      t.string :challenge_id_digest, limit: 64
      t.text :challenge_ciphertext
      t.datetime :challenge_expires_at
      t.datetime :challenge_rotated_at
      t.integer :challenge_rotations, null: false, default: 0
      t.datetime :ownership_verified_at
      t.datetime :activated_at
      t.datetime :removal_requested_at
      t.string :last_error_code, limit: 64
      t.timestamps
    end

    add_index :lla_custom_domains, :hostname, unique: true, name: 'idx_lla_custom_domains_hostname'
    add_index :lla_custom_domains, :portal_id, unique: true, name: 'idx_lla_custom_domains_portal'
    add_index :lla_custom_domains, :account_id, name: 'idx_lla_custom_domains_account'
    add_index :lla_custom_domains, %i[state updated_at], name: 'idx_lla_custom_domains_state'

    add_foreign_key :lla_custom_domains, :accounts, on_delete: :cascade, name: 'fk_lla_custom_domains_account'
    add_foreign_key :lla_custom_domains, :portals, on_delete: :cascade, name: 'fk_lla_custom_domains_portal'

    add_custom_domain_constraints
  end

  def add_custom_domain_constraints
    add_check_constraint :lla_custom_domains,
                         "state IN ('requested','ownership_pending','provisioning','active','failed','removing')",
                         name: 'chk_lla_custom_domains_state'
    add_check_constraint :lla_custom_domains, "provider IN ('none','cloudflare')",
                         name: 'chk_lla_custom_domains_provider'
    add_check_constraint :lla_custom_domains, HOSTNAME_SQL, name: 'chk_lla_custom_domains_hostname'
    add_check_constraint :lla_custom_domains, 'version >= 1 AND challenge_rotations BETWEEN 0 AND 10',
                         name: 'chk_lla_custom_domains_version'
    add_check_constraint :lla_custom_domains,
                         '(challenge_id_digest IS NULL AND challenge_ciphertext IS NULL AND challenge_expires_at IS NULL) OR ' \
                         '(char_length(challenge_id_digest) = 64 AND challenge_ciphertext IS NOT NULL AND challenge_expires_at IS NOT NULL)',
                         name: 'chk_lla_custom_domains_challenge'
    add_check_constraint :lla_custom_domains,
                         "state <> 'active' OR (ownership_verified_at IS NOT NULL AND activated_at IS NOT NULL)",
                         name: 'chk_lla_custom_domains_active'
    add_check_constraint :lla_custom_domains,
                         "provider_resource_id IS NULL OR (provider <> 'none' AND provider_resource_id ~ '^[A-Za-z0-9_-]{1,128}$')",
                         name: 'chk_lla_custom_domains_provider_resource'
  end

  def create_custom_domain_operations # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    create_table :lla_custom_domain_operations do |t|
      t.bigint :account_id, null: false
      t.bigint :custom_domain_id
      t.string :operation_type, null: false, limit: 32
      t.string :state, null: false, default: 'pending', limit: 32
      t.string :idempotency_digest, null: false, limit: 64
      t.string :request_digest, null: false, limit: 64
      t.string :claim_digest, limit: 64
      t.string :hostname, null: false, limit: 253
      t.string :provider, null: false, default: 'none', limit: 32
      t.string :provider_resource_id, limit: 128
      t.integer :domain_version, null: false, default: 1
      t.integer :attempts, null: false, default: 0
      t.integer :max_attempts, null: false, default: 5
      t.datetime :available_at, null: false
      t.datetime :claimed_at
      t.datetime :completed_at
      t.datetime :expires_at, null: false
      t.string :last_error_code, limit: 64
      t.timestamps
    end

    add_index :lla_custom_domain_operations, :idempotency_digest, unique: true,
                                                                  name: 'idx_lla_custom_domain_ops_idempotency'
    add_index :lla_custom_domain_operations, %i[state available_at], name: 'idx_lla_custom_domain_ops_dispatch'
    add_index :lla_custom_domain_operations, :custom_domain_id, name: 'idx_lla_custom_domain_ops_domain'
    add_index :lla_custom_domain_operations, :account_id, name: 'idx_lla_custom_domain_ops_account'

    add_foreign_key :lla_custom_domain_operations, :accounts, on_delete: :cascade,
                                                              name: 'fk_lla_custom_domain_ops_account'
    add_foreign_key :lla_custom_domain_operations, :lla_custom_domains, column: :custom_domain_id,
                                                                        on_delete: :nullify, name: 'fk_lla_custom_domain_ops_domain'

    add_operation_constraints
  end

  def add_operation_constraints
    add_check_constraint :lla_custom_domain_operations,
                         "operation_type IN ('provision','verify','remove','reconcile')",
                         name: 'chk_lla_custom_domain_ops_type'
    add_check_constraint :lla_custom_domain_operations,
                         "state IN ('pending','claimed','succeeded','failed','dead_lettered','cancelled')",
                         name: 'chk_lla_custom_domain_ops_state'
    add_check_constraint :lla_custom_domain_operations,
                         'char_length(idempotency_digest) = 64 AND char_length(request_digest) = 64 AND ' \
                         '(claim_digest IS NULL OR char_length(claim_digest) = 64)',
                         name: 'chk_lla_custom_domain_ops_digests'
    add_check_constraint :lla_custom_domain_operations,
                         'max_attempts BETWEEN 1 AND 5 AND attempts BETWEEN 0 AND max_attempts AND domain_version >= 1',
                         name: 'chk_lla_custom_domain_ops_attempts'
    add_check_constraint :lla_custom_domain_operations, "provider IN ('none','cloudflare')",
                         name: 'chk_lla_custom_domain_ops_provider'
    add_check_constraint :lla_custom_domain_operations, HOSTNAME_SQL,
                         name: 'chk_lla_custom_domain_ops_hostname'
  end

  # Existing portals already route on `portals.custom_domain`. The backfill keeps
  # that routing intact by materialising an explicit active lifecycle row for every
  # DNS-safe hostname; anything that cannot be canonicalised is deliberately left
  # out so it stops resolving instead of resolving from unvalidated state.
  def backfill_custom_domains
    execute <<~SQL.squish
      INSERT INTO lla_custom_domains
        (account_id, portal_id, hostname, state, version, provider,
         ownership_verified_at, activated_at, created_at, updated_at)
      SELECT portals.account_id, portals.id, lower(portals.custom_domain), 'active', 1, 'none',
             now(), now(), now(), now()
        FROM portals
       WHERE portals.custom_domain IS NOT NULL
         AND char_length(portals.custom_domain) BETWEEN 4 AND 253
         AND lower(portals.custom_domain) ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
       ORDER BY portals.id
      ON CONFLICT DO NOTHING
    SQL
  end

  # The superseded implementation kept the provider verification id and proof body
  # in `portals.ssl_settings` with no expiry. Ownership proofs now live encrypted
  # on the lifecycle row, so the legacy blob is dropped rather than migrated.
  # This is deliberately not restored by `down`.
  def scrub_legacy_ssl_settings
    execute <<~SQL.squish
      UPDATE portals SET ssl_settings = '{}'::jsonb WHERE ssl_settings IS NOT NULL AND ssl_settings <> '{}'::jsonb
    SQL
  end
end
