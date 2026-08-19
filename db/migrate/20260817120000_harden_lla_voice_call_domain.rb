# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength
class HardenLlaVoiceCallDomain < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INVALID_CALLS_SQL = <<~SQL.squish.freeze
    SELECT COUNT(*)
    FROM calls AS call
    LEFT JOIN inboxes AS inbox
      ON inbox.id = call.inbox_id AND inbox.account_id = call.account_id
    LEFT JOIN conversations AS conversation
      ON conversation.id = call.conversation_id
     AND conversation.account_id = call.account_id
     AND conversation.inbox_id = call.inbox_id
     AND conversation.contact_id = call.contact_id
    LEFT JOIN contacts AS contact
      ON contact.id = call.contact_id AND contact.account_id = call.account_id
    LEFT JOIN messages AS message
      ON message.id = call.message_id
     AND message.account_id = call.account_id
     AND message.conversation_id = call.conversation_id
    WHERE inbox.id IS NULL OR conversation.id IS NULL OR contact.id IS NULL
       OR (call.message_id IS NOT NULL AND message.id IS NULL)
       OR call.provider NOT IN (0, 1)
       OR call.direction NOT IN (0, 1)
       OR call.status NOT IN ('ringing', 'in_progress', 'completed', 'no_answer', 'failed', 'rejected')
  SQL

  def up
    normalize_calls
    ensure_call_integrity!
    add_call_indexes
    add_call_constraints
    add_call_foreign_keys
    create_call_events
    create_call_operations
  end

  def down
    drop_table :lla_call_operations, if_exists: true
    drop_table :lla_call_events, if_exists: true
    remove_call_foreign_keys
    remove_call_constraints
    remove_call_indexes
    restore_global_provider_identity_index
    change_column_null :calls, :meta, true
    remove_column :calls, :ended_at, if_exists: true
    remove_column :calls, :lock_version, if_exists: true
  end

  private

  def normalize_calls
    add_column :calls, :lock_version, :integer, null: false, default: 0 unless column_exists?(:calls, :lock_version)
    add_column :calls, :ended_at, :datetime unless column_exists?(:calls, :ended_at)
    execute "UPDATE calls SET meta = '{}'::jsonb WHERE meta IS NULL"
    backfill_legacy_ended_at
    change_column_default :calls, :meta, {}
    change_column_null :calls, :meta, false

    # A removed account membership must not leave a foreign accepted-agent ID.
    execute <<~SQL.squish
      UPDATE calls AS call
      SET accepted_by_agent_id = NULL
      WHERE accepted_by_agent_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM account_users AS membership
          WHERE membership.account_id = call.account_id
            AND membership.user_id = call.accepted_by_agent_id
        )
    SQL
  end

  def backfill_legacy_ended_at
    execute <<~SQL.squish
      UPDATE calls
      SET ended_at = to_timestamp((meta->>'ended_at')::double precision)
      WHERE ended_at IS NULL
        AND meta->>'ended_at' ~ '^\\d+(\\.\\d+)?$'
    SQL
  end

  def ensure_call_integrity!
    invalid = select_value(INVALID_CALLS_SQL).to_i
    return if invalid.zero?

    raise ActiveRecord::MigrationError,
          "#{invalid} calls have orphaned, cross-tenant or invalid state; repair them before retrying"
  end

  def add_call_indexes
    add_index :inboxes, %i[account_id id], unique: true, name: 'idx_lla_inboxes_tenant_id',
                                           algorithm: :concurrently, if_not_exists: true
    add_index :contacts, %i[account_id id], unique: true, name: 'idx_lla_contacts_tenant_id',
                                            algorithm: :concurrently, if_not_exists: true
    add_index :calls, %i[account_id id], unique: true, name: 'idx_lla_calls_tenant_id',
                                         algorithm: :concurrently, if_not_exists: true
    add_index :calls, %i[account_id inbox_id provider provider_call_id], unique: true,
                                                                         name: 'idx_lla_calls_provider_identity', algorithm: :concurrently,
                                                                         if_not_exists: true
    remove_index :calls, name: 'index_calls_on_provider_and_provider_call_id', if_exists: true
    add_index :calls, %i[account_id status created_at], name: 'idx_lla_calls_account_status_created',
                                                        algorithm: :concurrently, if_not_exists: true
    add_index :calls, %i[account_id inbox_id status updated_at], name: 'idx_lla_calls_inbox_active',
                                                                 algorithm: :concurrently, if_not_exists: true
  end

  def add_call_constraints
    add_validated_check :calls, 'provider IN (0, 1)', 'chk_lla_calls_provider'
    add_validated_check :calls, 'direction IN (0, 1)', 'chk_lla_calls_direction'
    add_validated_check :calls,
                        "status::text IN ('ringing'::text, 'in_progress'::text, 'completed'::text, " \
                        "'no_answer'::text, 'failed'::text, 'rejected'::text)",
                        'chk_lla_calls_status'
    add_validated_check :calls, 'duration_seconds IS NULL OR duration_seconds >= 0', 'chk_lla_calls_duration'
    add_validated_check :calls,
                        'char_length(provider_call_id) BETWEEN 1 AND 255',
                        'chk_lla_calls_provider_identity'
  end

  def add_call_foreign_keys
    add_validated_foreign_key :calls, :accounts, column: :account_id,
                                                 name: 'fk_lla_calls_account', on_delete: :cascade
    add_validated_foreign_key :calls, :inboxes,
                              column: %i[account_id inbox_id], primary_key: %i[account_id id],
                              name: 'fk_lla_calls_inbox_tenant', on_delete: :cascade
    add_validated_foreign_key :calls, :conversations,
                              column: %i[account_id conversation_id], primary_key: %i[account_id id],
                              name: 'fk_lla_calls_conversation_tenant', on_delete: :cascade
    add_validated_foreign_key :calls, :contacts,
                              column: %i[account_id contact_id], primary_key: %i[account_id id],
                              name: 'fk_lla_calls_contact_tenant', on_delete: :cascade
    add_validated_foreign_key :calls, :messages,
                              column: %i[account_id message_id conversation_id],
                              primary_key: %i[account_id id conversation_id],
                              name: 'fk_lla_calls_message_tenant'
    add_validated_foreign_key :calls, :users, column: :accepted_by_agent_id,
                                              name: 'fk_lla_calls_accepted_agent', on_delete: :nullify
  end

  def create_call_events
    return if table_exists?(:lla_call_events)

    create_call_events_table
    add_call_event_integrity
  end

  def create_call_events_table
    create_table :lla_call_events do |t|
      t.bigint :account_id, null: false
      t.bigint :inbox_id, null: false
      t.bigint :call_id
      t.integer :provider, null: false
      t.string :event_id_digest, null: false, limit: 64
      t.string :payload_digest, null: false, limit: 64
      t.string :event_type, null: false, limit: 80
      t.string :outcome, null: false, default: 'pending', limit: 16
      t.datetime :occurred_at
      t.datetime :verified_at, null: false
      t.timestamps
    end
  end

  def add_call_event_integrity
    add_index :lla_call_events, %i[account_id inbox_id provider event_id_digest], unique: true,
                                                                                  name: 'idx_lla_call_events_idempotency'
    add_index :lla_call_events, %i[account_id call_id created_at], name: 'idx_lla_call_events_call_timeline'
    add_foreign_key :lla_call_events, :accounts, on_delete: :cascade
    add_foreign_key :lla_call_events, :inboxes,
                    column: %i[account_id inbox_id], primary_key: %i[account_id id],
                    name: 'fk_lla_call_events_inbox_tenant', on_delete: :cascade
    add_foreign_key :lla_call_events, :calls,
                    column: %i[account_id call_id], primary_key: %i[account_id id],
                    name: 'fk_lla_call_events_call_tenant', on_delete: :cascade
    add_check_constraint :lla_call_events, 'provider IN (0, 1)', name: 'chk_lla_call_events_provider'
    add_check_constraint :lla_call_events,
                         "outcome::text IN ('pending'::text, 'applied'::text, 'duplicate'::text, 'stale'::text, 'rejected'::text)",
                         name: 'chk_lla_call_events_outcome'
    add_check_constraint :lla_call_events,
                         'char_length(event_id_digest) = 64 AND char_length(payload_digest) = 64',
                         name: 'chk_lla_call_events_digests'
  end

  def create_call_operations
    return if table_exists?(:lla_call_operations)

    create_call_operations_table
    add_call_operation_integrity
  end

  def create_call_operations_table
    create_table :lla_call_operations do |t|
      t.bigint :account_id, null: false
      t.bigint :inbox_id, null: false
      t.bigint :call_id
      t.string :action, null: false, limit: 32
      t.string :state, null: false, default: 'pending', limit: 16
      t.string :idempotency_digest, null: false, limit: 64
      t.string :request_digest, null: false, limit: 64
      t.string :claim_digest, limit: 64
      t.string :provider_request_id_digest, limit: 64
      t.string :last_error_code, limit: 80
      t.integer :attempts, null: false, default: 0
      t.datetime :available_at, null: false
      t.datetime :claimed_at
      t.datetime :completed_at
      t.timestamps
    end
  end

  def add_call_operation_integrity
    idempotency_index = { unique: true, name: 'idx_lla_call_operations_idempotency' }
    add_index :lla_call_operations, %i[account_id inbox_id idempotency_digest], **idempotency_index
    add_index :lla_call_operations, %i[state available_at], name: 'idx_lla_call_operations_ready'
    add_foreign_key :lla_call_operations, :accounts, on_delete: :cascade
    add_foreign_key :lla_call_operations, :inboxes,
                    column: %i[account_id inbox_id], primary_key: %i[account_id id],
                    name: 'fk_lla_call_operations_inbox_tenant', on_delete: :cascade
    add_foreign_key :lla_call_operations, :calls,
                    column: %i[account_id call_id], primary_key: %i[account_id id],
                    name: 'fk_lla_call_operations_call_tenant', on_delete: :cascade
    add_check_constraint :lla_call_operations,
                         "state::text IN ('pending'::text, 'claimed'::text, 'succeeded'::text, " \
                         "'failed'::text, 'compensating'::text, 'compensated'::text)",
                         name: 'chk_lla_call_operations_state'
    add_check_constraint :lla_call_operations,
                         'char_length(idempotency_digest) = 64 AND char_length(request_digest) = 64',
                         name: 'chk_lla_call_operations_digests'
    add_check_constraint :lla_call_operations, 'attempts BETWEEN 0 AND 20',
                         name: 'chk_lla_call_operations_attempts'
  end

  def add_validated_check(table, expression, name)
    add_check_constraint table, expression, name: name, validate: false, if_not_exists: true
    validate_check_constraint table, name: name
  end

  def add_validated_foreign_key(from_table, to_table, **options)
    add_foreign_key from_table, to_table, **options, validate: false, if_not_exists: true
    validate_foreign_key from_table, name: options.fetch(:name)
  end

  def remove_call_foreign_keys
    %w[
      fk_lla_calls_account
      fk_lla_calls_inbox_tenant
      fk_lla_calls_conversation_tenant
      fk_lla_calls_contact_tenant
      fk_lla_calls_message_tenant
      fk_lla_calls_accepted_agent
    ].each { |name| remove_foreign_key :calls, name: name, if_exists: true }
  end

  def remove_call_constraints
    %w[
      chk_lla_calls_provider
      chk_lla_calls_direction
      chk_lla_calls_status
      chk_lla_calls_duration
      chk_lla_calls_provider_identity
    ].each { |name| remove_check_constraint :calls, name: name, if_exists: true }
  end

  def remove_call_indexes
    %w[
      idx_lla_calls_account_status_created
      idx_lla_calls_inbox_active
      idx_lla_calls_provider_identity
      idx_lla_calls_tenant_id
    ].each { |name| remove_index :calls, name: name, if_exists: true }
    remove_index :inboxes, name: 'idx_lla_inboxes_tenant_id', if_exists: true
    remove_index :contacts, name: 'idx_lla_contacts_tenant_id', if_exists: true
  end

  def restore_global_provider_identity_index
    options = {
      unique: true,
      name: 'index_calls_on_provider_and_provider_call_id',
      algorithm: :concurrently,
      if_not_exists: true
    }
    add_index :calls, %i[provider provider_call_id], **options
  end
end
# rubocop:enable Metrics/ClassLength
