# frozen_string_literal: true

class CreateLlaCustomDomainLifecycle < ActiveRecord::Migration[7.1] # rubocop:disable Metrics/ClassLength
  HOSTNAME_SQL = 'hostname = lower(hostname) AND char_length(hostname) BETWEEN 4 AND 253 AND ' \
                 "hostname ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'"
  # A tombstone is evidence, not a routing key: it has to be able to record exactly
  # the legacy value that could *not* be canonicalised, so it only rejects empty,
  # over-long and whitespace/control-character values.
  TOMBSTONE_HOSTNAME_SQL = "char_length(hostname) BETWEEN 1 AND 253 AND hostname !~ '[[:space:][:cntrl:]]'"

  # `portals.custom_domain` used to route on its own. The backfill materialises an
  # explicit lifecycle row so routing keeps working, but it never invents an
  # ownership proof: legacy rows are marked `legacy_import` and flagged for
  # reverification, and `portals.ssl_settings` is left byte-for-byte untouched.
  # Scrubbing the legacy challenge material is a separate, owner-approved and
  # non-reversible cleanup that is deliberately not part of this migration.
  def up
    create_custom_domains
    create_custom_domain_operations
    create_custom_domain_tombstones
    backfill_custom_domains
  end

  def down
    drop_table :lla_custom_domain_tombstones, if_exists: true
    drop_table :lla_custom_domain_operations, if_exists: true
    drop_table :lla_custom_domains, if_exists: true
  end

  private

  def create_custom_domains # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    create_table :lla_custom_domains do |t|
      t.integer :account_id, null: false
      t.bigint :portal_id, null: false
      t.string :hostname, null: false, limit: 253
      t.string :state, null: false, default: 'requested', limit: 32
      t.integer :version, null: false, default: 1
      t.string :provider, null: false, default: 'none', limit: 32
      t.string :provider_resource_id, limit: 128
      t.string :provider_status, limit: 64
      t.datetime :provider_synced_at
      t.string :ownership_source, null: false, default: 'nonce_challenge', limit: 32
      t.boolean :reverify_required, null: false, default: false
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
    # Referenced side of the operations composite tenant foreign key.
    add_index :lla_custom_domains, %i[id account_id], unique: true, name: 'idx_lla_custom_domains_tenant_key'

    add_foreign_key :lla_custom_domains, :accounts, on_delete: :cascade, name: 'fk_lla_custom_domains_account'
    # The referenced side is the UNIQUE index `idx_lla_portals_tenant_identity` on
    # portals (account_id, id): PostgreSQL matches a composite foreign key against a
    # unique index by column *set*, so no second index has to be built on `portals`.
    execute <<~SQL.squish
      ALTER TABLE lla_custom_domains
        ADD CONSTRAINT fk_lla_custom_domains_portal_tenant
        FOREIGN KEY (portal_id, account_id) REFERENCES portals (id, account_id) ON DELETE CASCADE
    SQL

    add_custom_domain_constraints
  end

  def add_custom_domain_constraints # rubocop:disable Metrics/MethodLength
    add_check_constraint :lla_custom_domains,
                         "state IN ('requested','ownership_pending','provisioning','active','failed','removing')",
                         name: 'chk_lla_custom_domains_state'
    add_check_constraint :lla_custom_domains, "provider IN ('none','cloudflare')",
                         name: 'chk_lla_custom_domains_provider'
    add_check_constraint :lla_custom_domains, "ownership_source IN ('nonce_challenge','legacy_import')",
                         name: 'chk_lla_custom_domains_ownership_source'
    add_check_constraint :lla_custom_domains, HOSTNAME_SQL, name: 'chk_lla_custom_domains_hostname'
    add_check_constraint :lla_custom_domains, 'version >= 1 AND challenge_rotations BETWEEN 0 AND 10',
                         name: 'chk_lla_custom_domains_version'
    add_check_constraint :lla_custom_domains,
                         '(challenge_id_digest IS NULL AND challenge_ciphertext IS NULL AND challenge_expires_at IS NULL) OR ' \
                         '(challenge_id_digest IS NOT NULL AND char_length(challenge_id_digest) = 64 ' \
                         'AND challenge_ciphertext IS NOT NULL AND challenge_expires_at IS NOT NULL)',
                         name: 'chk_lla_custom_domains_challenge'
    # An `active` row is either backed by a completed nonce proof, or it is an
    # honestly labelled legacy import that still owes a reverification.
    add_check_constraint :lla_custom_domains,
                         "state <> 'active' OR " \
                         "(ownership_source = 'nonce_challenge' AND ownership_verified_at IS NOT NULL " \
                         'AND activated_at IS NOT NULL AND reverify_required = FALSE) OR ' \
                         "(ownership_source = 'legacy_import' AND ownership_verified_at IS NULL " \
                         'AND activated_at IS NULL AND reverify_required = TRUE)',
                         name: 'chk_lla_custom_domains_active'
    add_check_constraint :lla_custom_domains,
                         "state <> 'removing' OR removal_requested_at IS NOT NULL",
                         name: 'chk_lla_custom_domains_removing'
    add_check_constraint :lla_custom_domains,
                         "provider_resource_id IS NULL OR (provider <> 'none' AND provider_resource_id ~ '^[A-Za-z0-9_-]{1,128}$')",
                         name: 'chk_lla_custom_domains_provider_resource'
  end

  def create_custom_domain_operations # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    create_table :lla_custom_domain_operations do |t|
      t.integer :account_id, null: false
      t.bigint :custom_domain_id
      t.bigint :predecessor_id
      t.integer :recovery_attempt, null: false, default: 0
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
      t.integer :deferrals, null: false, default: 0
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
    add_index :lla_custom_domain_operations, %i[state claimed_at], name: 'idx_lla_custom_domain_ops_claims'
    add_index :lla_custom_domain_operations, :custom_domain_id, name: 'idx_lla_custom_domain_ops_domain'
    add_index :lla_custom_domain_operations, :account_id, name: 'idx_lla_custom_domain_ops_account'
    add_index :lla_custom_domain_operations, :predecessor_id, name: 'idx_lla_custom_domain_ops_predecessor'
    add_foreign_key :lla_custom_domain_operations, :lla_custom_domain_operations, column: :predecessor_id,
                                                                                  on_delete: :nullify, name: 'fk_lla_custom_domain_ops_predecessor'

    add_foreign_key :lla_custom_domain_operations, :accounts, on_delete: :cascade,
                                                              name: 'fk_lla_custom_domain_ops_account'
    # Composite: an operation can only ever point at a domain of its own tenant.
    # Teardown snapshots deliberately carry a NULL domain id and survive the
    # cascade, which is what keeps a remote resource removable after the row is gone.
    execute <<~SQL.squish
      ALTER TABLE lla_custom_domain_operations
        ADD CONSTRAINT fk_lla_custom_domain_ops_domain_tenant
        FOREIGN KEY (custom_domain_id, account_id) REFERENCES lla_custom_domains (id, account_id) ON DELETE CASCADE
    SQL

    add_operation_constraints
  end

  def add_operation_constraints # rubocop:disable Metrics/MethodLength
    add_check_constraint :lla_custom_domain_operations,
                         "operation_type IN ('provision','verify','reverify','remove','reconcile')",
                         name: 'chk_lla_custom_domain_ops_type'
    add_check_constraint :lla_custom_domain_operations,
                         "state IN ('pending','deferred','claimed','succeeded','failed','dead_lettered','cancelled')",
                         name: 'chk_lla_custom_domain_ops_state'
    add_check_constraint :lla_custom_domain_operations,
                         'char_length(idempotency_digest) = 64 AND char_length(request_digest) = 64 AND ' \
                         '(claim_digest IS NULL OR char_length(claim_digest) = 64)',
                         name: 'chk_lla_custom_domain_ops_digests'
    add_check_constraint :lla_custom_domain_operations,
                         'max_attempts BETWEEN 1 AND 5 AND attempts BETWEEN 0 AND max_attempts AND ' \
                         'domain_version >= 1 AND deferrals BETWEEN 0 AND 1000 AND ' \
                         'recovery_attempt BETWEEN 0 AND 3',
                         name: 'chk_lla_custom_domain_ops_attempts'
    # A recovery successor always names the terminal row it replaces, and a first
    # generation operation never claims to be one.
    add_check_constraint :lla_custom_domain_operations,
                         '(recovery_attempt = 0 AND predecessor_id IS NULL) OR ' \
                         '(recovery_attempt > 0 AND predecessor_id IS NOT NULL)',
                         name: 'chk_lla_custom_domain_ops_recovery'
    add_check_constraint :lla_custom_domain_operations, "provider IN ('none','cloudflare')",
                         name: 'chk_lla_custom_domain_ops_provider'
    add_check_constraint :lla_custom_domain_operations, HOSTNAME_SQL,
                         name: 'chk_lla_custom_domain_ops_hostname'
    # Claim/terminal coherence: a claimed row always carries its claim, a waiting
    # row never does, and a finished row is always stamped and unclaimed.
    add_check_constraint :lla_custom_domain_operations,
                         "(state = 'claimed' AND claim_digest IS NOT NULL AND claimed_at IS NOT NULL AND completed_at IS NULL) OR " \
                         "(state IN ('pending','deferred') AND claim_digest IS NULL AND completed_at IS NULL) OR " \
                         "(state IN ('succeeded','failed','dead_lettered','cancelled') AND claim_digest IS NULL " \
                         'AND completed_at IS NOT NULL)',
                         name: 'chk_lla_custom_domain_ops_claim_state'
  end

  # Durable, operator-visible evidence for a hostname whose remote provider resource
  # may still exist while LLA never learned its ID (pre-lifecycle imports). It must
  # outlive both the domain row and the operation retention window, so it is a table
  # of its own rather than a flag on either.
  def create_custom_domain_tombstones # rubocop:disable Metrics/MethodLength
    create_table :lla_custom_domain_tombstones do |t|
      t.integer :account_id, null: false
      t.bigint :portal_id
      t.string :hostname, null: false, limit: 253
      t.string :reason, null: false, limit: 64
      t.string :provider, null: false, default: 'none', limit: 32
      t.string :provider_status_hint, limit: 64
      t.string :state, null: false, default: 'manual_adoption_required', limit: 32
      t.datetime :resolved_at
      t.string :resolved_by_reference, limit: 64
      t.timestamps
    end

    add_index :lla_custom_domain_tombstones, %i[account_id hostname], unique: true,
                                                                      name: 'idx_lla_custom_domain_tombstones_host'
    add_index :lla_custom_domain_tombstones, %i[state created_at], name: 'idx_lla_custom_domain_tombstones_state'
    add_foreign_key :lla_custom_domain_tombstones, :accounts, on_delete: :cascade,
                                                              name: 'fk_lla_custom_domain_tombstones_account'

    add_check_constraint :lla_custom_domain_tombstones,
                         "state IN ('manual_adoption_required','resolved')",
                         name: 'chk_lla_custom_domain_tombstones_state'
    add_check_constraint :lla_custom_domain_tombstones,
                         "reason IN ('legacy_provider_resource_unknown','provider_teardown_abandoned'," \
                         "'legacy_hostname_unsupported','legacy_hostname_duplicate')",
                         name: 'chk_lla_custom_domain_tombstones_reason'
    add_check_constraint :lla_custom_domain_tombstones,
                         "state <> 'resolved' OR resolved_at IS NOT NULL",
                         name: 'chk_lla_custom_domain_tombstones_resolved'
    add_check_constraint :lla_custom_domain_tombstones, TOMBSTONE_HOSTNAME_SQL,
                         name: 'chk_lla_custom_domain_tombstones_hostname'
  end

  # Backfill goes through the real canonicalizer, so a hostname the runtime would
  # reject never becomes a lifecycle row (and therefore stops resolving) instead of
  # being smuggled in by a looser SQL regexp.
  #
  # A legacy value the canonicalizer refuses — or a second portal that collapses onto
  # a hostname another portal already took — stops routing at this migration. That is
  # a deliberate, but never a *silent*, outcome: every dropped value leaves a
  # tombstone naming the portal, so the change is an operator work list rather than
  # an invisible outage. `portals.custom_domain` itself is left untouched, so nothing
  # is lost and the operator can re-enter a supported hostname.
  def backfill_custom_domains
    seen = Set.new
    now = Time.current

    legacy_portals.each do |row|
      hostname = Lla::CustomDomains::HostCanonicalizer.canonicalize(row['custom_domain'])
      next record_dropped_legacy(row, 'legacy_hostname_unsupported', now) if hostname.blank?
      next record_dropped_legacy(row, 'legacy_hostname_duplicate', now) if seen.include?(hostname)

      seen << hostname
      insert_legacy_domain(row, hostname, now)
    end
  end

  # Evidence for a portal whose custom domain no longer resolves after this
  # migration. Stored verbatim (bounded) because the whole point is to name the
  # value the canonicalizer could not represent.
  def record_dropped_legacy(row, reason, now)
    raw = row['custom_domain'].to_s.strip[0, 253].to_s
    return if raw.blank? || raw.match?(/[[:space:][:cntrl:]]/)

    execute(<<~SQL.squish)
      INSERT INTO lla_custom_domain_tombstones
        (account_id, portal_id, hostname, reason, provider, state, created_at, updated_at)
      VALUES (#{quote(row['account_id'])}, #{quote(row['id'])}, #{quote(raw)}, #{quote(reason)}, 'none',
              'manual_adoption_required', #{quote(now)}, #{quote(now)})
      ON CONFLICT DO NOTHING
    SQL
  end

  def legacy_portals
    ActiveRecord::Base.connection.select_all(
      'SELECT id, account_id, custom_domain, ssl_settings FROM portals WHERE custom_domain IS NOT NULL ORDER BY id'
    ).to_a
  end

  # `cf_status` is the only legacy evidence that exists; it is carried across as
  # provider status for audit and never converted into an ownership proof.
  def insert_legacy_domain(row, hostname, now)
    settings = parse_settings(row['ssl_settings'])
    status = settings['cf_status'].to_s.presence&.first(64)

    execute(<<~SQL.squish)
      INSERT INTO lla_custom_domains
        (account_id, portal_id, hostname, state, version, provider, provider_status,
         ownership_source, reverify_required, created_at, updated_at)
      VALUES (#{quote(row['account_id'])}, #{quote(row['id'])}, #{quote(hostname)}, 'active', 1, 'none',
              #{quote(status)}, 'legacy_import', TRUE, #{quote(now)}, #{quote(now)})
      ON CONFLICT DO NOTHING
    SQL
  end

  def parse_settings(value)
    parsed = value.is_a?(String) ? JSON.parse(value.presence || '{}') : value
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
