# frozen_string_literal: true

class CreateLlaCustomDomainLifecycle < ActiveRecord::Migration[7.1] # rubocop:disable Metrics/ClassLength
  HOSTNAME_SQL = 'hostname = lower(hostname) AND char_length(hostname) BETWEEN 4 AND 253 AND ' \
                 "hostname ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'"
  # A tombstone is evidence, not a routing key. The hostname column therefore only
  # ever holds a value that *is* representable as a host, and is NULL for evidence
  # about a value that is not — the unsafe original is preserved as a bounded,
  # printable preview plus the digest of its exact bytes.
  TOMBSTONE_HOSTNAME_SQL = 'hostname IS NULL OR (' \
                           "char_length(hostname) BETWEEN 1 AND 253 AND hostname !~ '[[:space:][:cntrl:]]')"
  TOMBSTONE_EVIDENCE_SQL = 'char_length(evidence_key) BETWEEN 1 AND 128 AND ' \
                           "evidence_key ~ '^[a-z0-9_.:-]+$' AND " \
                           "(source_value_digest IS NULL OR source_value_digest ~ '^[0-9a-f]{64}$') AND " \
                           "(provider_resource_digest IS NULL OR provider_resource_digest ~ '^[0-9a-f]{64}$') AND " \
                           "(provider_resource_id IS NULL OR provider_resource_id ~ '^[A-Za-z0-9_-]{1,128}$') AND " \
                           '(source_value_preview IS NULL OR (' \
                           'char_length(source_value_preview) BETWEEN 1 AND 253 AND ' \
                           "source_value_preview !~ '[[:cntrl:]]'))"
  # What each kind of evidence must be able to answer. A dropped legacy value must
  # name the portal an operator has to fix and carry a reference to the exact
  # original bytes; evidence about a live remote resource must name the hostname.
  #
  # The portal named is `source_portal_id`, not `portal_id`: the first is the
  # immutable audit fact this evidence is *about*, the second is the live foreign
  # key that is detached if the portal is later deleted.
  TOMBSTONE_REASON_SHAPE_SQL = "reason NOT IN ('legacy_hostname_unsupported','legacy_hostname_duplicate'," \
                               "'legacy_hostname_contested','legacy_hostname_unroutable') OR " \
                               '(source_portal_id IS NOT NULL AND source_value_digest IS NOT NULL ' \
                               'AND source_value_preview IS NOT NULL)'
  TOMBSTONE_RESOURCE_SHAPE_SQL = "reason NOT IN ('legacy_provider_resource_unknown','provider_teardown_abandoned') " \
                                 'OR hostname IS NOT NULL'
  # An abandoned teardown is the one kind of evidence that names a remote object LLA
  # *knows* exists. It is only actionable if it carries that object's identifier and
  # the provider it lives at, so the schema refuses the shape that cannot be acted on.
  TOMBSTONE_ABANDONED_SHAPE_SQL = "reason <> 'provider_teardown_abandoned' OR " \
                                  "(provider <> 'none' AND provider_resource_id IS NOT NULL " \
                                  'AND provider_resource_digest IS NOT NULL)'
  # The live reference may be detached, but it can never point somewhere else: while
  # it is set it is the portal the evidence was recorded for.
  TOMBSTONE_PORTAL_SHAPE_SQL = 'portal_id IS NULL OR portal_id = source_portal_id'

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
      # Live tenant-checked reference: detached (NULL) if the portal is deleted.
      t.bigint :portal_id
      # Immutable audit reference: which portal this evidence is about, forever.
      t.bigint :source_portal_id
      t.string :hostname, limit: 253
      t.string :reason, null: false, limit: 64
      # Identity of one piece of evidence. It is deliberately *not* the hostname:
      # several portals in one account can lose the same hostname, and each of them
      # is a separate thing an operator has to fix.
      t.string :evidence_key, null: false, limit: 128
      t.string :source_value_digest, limit: 64
      t.string :source_value_preview, limit: 253
      t.string :provider, null: false, default: 'none', limit: 32
      # The identifier of the remote object that is still out there, and its SHA-256
      # fingerprint. The fingerprint is what identity and telemetry use; the raw id
      # never appears in an evidence key or a log line, only in this column, because
      # it is the one thing that lets an operator delete the object after the
      # operation that knew about it has been purged.
      t.string :provider_resource_id, limit: 128
      t.string :provider_resource_digest, limit: 64
      t.string :provider_status_hint, limit: 64
      t.string :state, null: false, default: 'manual_adoption_required', limit: 32
      t.datetime :resolved_at
      t.string :resolved_by_reference, limit: 64
      t.timestamps
    end

    add_tombstone_indexes
    add_tombstone_constraints
  end

  def add_tombstone_indexes
    add_index :lla_custom_domain_tombstones, %i[account_id evidence_key], unique: true,
                                                                          name: 'idx_lla_custom_domain_tombstones_key'
    add_index :lla_custom_domain_tombstones, %i[account_id hostname], name: 'idx_lla_custom_domain_tombstones_host'
    add_index :lla_custom_domain_tombstones, :portal_id, name: 'idx_lla_custom_domain_tombstones_portal'
    add_index :lla_custom_domain_tombstones, %i[account_id source_portal_id],
              name: 'idx_lla_custom_domain_tombstones_source_portal'
    add_index :lla_custom_domain_tombstones, %i[state created_at], name: 'idx_lla_custom_domain_tombstones_state'
    add_foreign_key :lla_custom_domain_tombstones, :accounts, on_delete: :cascade,
                                                              name: 'fk_lla_custom_domain_tombstones_account'
    # The tenant boundary, enforced by PostgreSQL rather than by a model: evidence of
    # account A can only ever name a portal of account A. No `ON DELETE` action is
    # declared on purpose — evidence must neither be cascaded away with the portal
    # nor left pointing at a row that no longer exists, so the database refuses a
    # portal delete that would orphan it and the application detaches the live
    # reference first (`Lla::Concerns::Portal`), keeping `source_portal_id`.
    execute <<~SQL.squish
      ALTER TABLE lla_custom_domain_tombstones
        ADD CONSTRAINT fk_lla_custom_domain_tombstones_portal_tenant
        FOREIGN KEY (portal_id, account_id) REFERENCES portals (id, account_id)
    SQL
  end

  def add_tombstone_constraints
    add_tombstone_shape_constraints
    add_check_constraint :lla_custom_domain_tombstones,
                         "state IN ('manual_adoption_required','resolved')",
                         name: 'chk_lla_custom_domain_tombstones_state'
    add_check_constraint :lla_custom_domain_tombstones,
                         "reason IN ('legacy_provider_resource_unknown','provider_teardown_abandoned'," \
                         "'legacy_hostname_unsupported','legacy_hostname_duplicate'," \
                         "'legacy_hostname_contested','legacy_hostname_unroutable')",
                         name: 'chk_lla_custom_domain_tombstones_reason'
    add_check_constraint :lla_custom_domain_tombstones,
                         "state <> 'resolved' OR resolved_at IS NOT NULL",
                         name: 'chk_lla_custom_domain_tombstones_resolved'
  end

  def add_tombstone_shape_constraints
    add_check_constraint :lla_custom_domain_tombstones, TOMBSTONE_HOSTNAME_SQL,
                         name: 'chk_lla_custom_domain_tombstones_hostname'
    add_check_constraint :lla_custom_domain_tombstones, TOMBSTONE_EVIDENCE_SQL,
                         name: 'chk_lla_custom_domain_tombstones_evidence'
    add_check_constraint :lla_custom_domain_tombstones, TOMBSTONE_REASON_SHAPE_SQL,
                         name: 'chk_lla_custom_domain_tombstones_shape'
    add_check_constraint :lla_custom_domain_tombstones, TOMBSTONE_RESOURCE_SHAPE_SQL,
                         name: 'chk_lla_custom_domain_tombstones_resource'
    add_check_constraint :lla_custom_domain_tombstones, TOMBSTONE_ABANDONED_SHAPE_SQL,
                         name: 'chk_lla_custom_domain_tombstones_abandoned'
    add_check_constraint :lla_custom_domain_tombstones, TOMBSTONE_PORTAL_SHAPE_SQL,
                         name: 'chk_lla_custom_domain_tombstones_portal'
  end

  # Backfill goes through the real canonicalizer, so a hostname the runtime would
  # reject never becomes a lifecycle row (and therefore stops resolving) instead of
  # being smuggled in by a looser SQL regexp.
  #
  # A legacy value the canonicalizer refuses — or a second portal that collapses onto
  # a hostname another portal already took — stops routing at this migration. That is
  # a deliberate, but never a *silent*, outcome: **every** dropped non-empty value
  # leaves one evidence row naming the portal an operator has to fix, whatever the
  # value contains. `portals.custom_domain` itself is left untouched, so nothing is
  # lost and the operator can re-enter a supported hostname.
  def backfill_custom_domains
    now = Time.current
    groups = legacy_portals.group_by { |row| Lla::CustomDomains::HostCanonicalizer.canonicalize(row['custom_domain']) }

    groups.each do |hostname, rows|
      next rows.each { |row| record_dropped_legacy(row, 'legacy_hostname_unsupported', nil, now) } if hostname.blank?

      import_legacy_group(hostname, rows, now)
    end
  end

  def import_legacy_group(hostname, rows, now)
    routed, unroutable = rows.partition { |row| routed_form?(row['custom_domain'], hostname) }

    unroutable.each { |row| record_dropped_legacy(row, 'legacy_hostname_unroutable', hostname, now) }
    import_routed_group(hostname, routed, now)
  end

  def import_routed_group(hostname, rows, now)
    owner = elect_legacy_owner(hostname, rows)
    reason = owner ? 'legacy_hostname_duplicate' : 'legacy_hostname_contested'

    rows.each do |row|
      next insert_legacy_domain(row, hostname, now) if owner && row['id'] == owner['id']

      record_dropped_legacy(row, reason, hostname, now)
    end
  end

  # Could this stored value ever have been the `Host` of a request?
  #
  # Legacy routing was `Portal.find_by(custom_domain: request.host)` — an exact
  # string comparison. Case and a trailing dot are the only differences a normal
  # client erases on its way to that comparison, so those variants plausibly served.
  # Everything else the canonicalizer folds — NFKC, IDNA — produces a hostname the
  # stored value could not have matched: a browser sends punycode, not `ｄｏｃｓ`.
  # Importing such a row would hand its account a hostname it demonstrably never
  # served, take the globally unique row for it, and lock out whoever does own it.
  # So it is evidence, not a claim.
  def routed_form?(raw, hostname)
    value = raw.to_s.strip
    # ASCII first, and not as an optimisation: `String#downcase` is Unicode-aware, so
    # U+212A KELVIN SIGN lowercases to a plain `k` and a value spelled with it would
    # otherwise pass for the case variant of a hostname it could never have matched.
    # A hostname is ASCII by the time it routes (IDNs arrive as punycode), so a
    # non-ASCII stored value is never the form that was compared against `Host`.
    return false unless value.ascii_only?

    value.chomp('.').downcase == hostname
  end

  # Which portal was actually serving this hostname before the lifecycle existed.
  #
  # Legacy routing matched `portals.custom_domain` exactly and the column is globally
  # unique, so at most one row can hold the canonical host itself — that row, and only
  # that row, was resolving. Every other row in the group is a case or trailing-dot
  # variant that never served anything.
  #
  # When no row holds the canonical value the group is ambiguous. Inside one account
  # that is harmless: the tenant keeps the hostname either way and an operator sorts
  # out which portal. Across accounts there is no fact that says whose it is, and the
  # imported row would route immediately, so importing either one would hand a tenant
  # a hostname it never proved and cannot be shown to have served. Nobody gets it, and
  # every portal in the group gets its own evidence instead.
  def elect_legacy_owner(hostname, rows)
    exact = rows.find { |row| row['custom_domain'] == hostname }
    return exact if exact
    return if rows.pluck('account_id').uniq.size > 1

    rows.first
  end

  # Evidence for one portal whose custom domain no longer resolves after this
  # migration.
  #
  # The original value is *not* forced into the hostname column: it may contain
  # whitespace, control characters or be far longer than a host, and a routing-key
  # column must not carry it. What survives instead identifies it exactly and safely
  # — the SHA-256 of the original bytes, a bounded printable preview, and the portal
  # id — while `hostname` holds the canonical host only when there is one (the
  # duplicate case, where knowing which host was lost is what an operator needs).
  #
  # The evidence key is per portal, so two, three or more portals in one account
  # losing the same hostname each keep their own row; re-running the migration
  # recomputes the same keys and inserts nothing new.
  def record_dropped_legacy(row, reason, hostname, now)
    raw = row['custom_domain'].to_s
    return if raw.empty?

    digest = Digest::SHA256.hexdigest(raw)
    insert_with_binds(<<~SQL.squish,
      INSERT INTO lla_custom_domain_tombstones
        (account_id, portal_id, source_portal_id, hostname, reason, evidence_key, source_value_digest,
         source_value_preview, provider, state, created_at, updated_at)
      VALUES ($1, $2, $2, $3, $4, $5, $6, $7, 'none', 'manual_adoption_required', $8, $8)
      ON CONFLICT DO NOTHING
    SQL
                      [row['account_id'], row['id'], hostname, reason,
                       evidence_key(reason, row['id'], digest), digest, safe_preview(raw), now])
  end

  # Values go in as bind parameters, never as interpolated literals: `squish` runs
  # over the whole statement, so an interpolated value containing whitespace would be
  # silently rewritten on its way into the row — and legacy data is exactly where
  # such values live.
  def insert_with_binds(sql, binds)
    ActiveRecord::Base.connection.exec_query(sql, 'lla_custom_domain_backfill', binds)
  end

  def evidence_key(reason, portal_id, digest)
    "#{reason}:#{portal_id}:#{digest[0, 32]}"
  end

  # Printable, bounded, and never blank: every byte outside printable ASCII becomes
  # `?` and every whitespace byte becomes `_`, so the preview can be read in a
  # terminal, stored in a plain column and still shows the shape of what was there.
  def safe_preview(raw)
    printable = raw.dup.force_encoding(Encoding::BINARY)
                   .gsub(/[[:space:]]/n, '_')
                   .gsub(/[^\x20-\x7E]/n, '?')
    truncated = printable[0, 200].to_s
    suffix = printable.bytesize > 200 ? "...+#{printable.bytesize - 200}" : ''
    value = "#{truncated}#{suffix}"
    value.empty? ? '(empty)' : value.force_encoding(Encoding::UTF_8)
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

    insert_with_binds(<<~SQL.squish,
      INSERT INTO lla_custom_domains
        (account_id, portal_id, hostname, state, version, provider, provider_status,
         ownership_source, reverify_required, created_at, updated_at)
      VALUES ($1, $2, $3, 'active', 1, 'none', $4, 'legacy_import', TRUE, $5, $5)
      ON CONFLICT DO NOTHING
    SQL
                      [row['account_id'], row['id'], hostname, status, now])
  end

  def parse_settings(value)
    parsed = value.is_a?(String) ? JSON.parse(value.presence || '{}') : value
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end
