# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength
class HardenLlaCaptainOperationsAndFeedback < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  REPORT_REASONS = %w[incorrect_information inappropriate_response incomplete_response outdated_information other].freeze

  def up
    add_feedback_retention
    reconcile_feedback_tenancy
    deduplicate_feedback
    ensure_feedback_integrity!
    add_feedback_indexes
    add_feedback_constraints
    add_feedback_foreign_keys
    add_document_sync_claims
    create_bulk_operations
  end

  def down
    drop_table :lla_captain_bulk_operations, if_exists: true

    remove_column :captain_documents, :sync_claimed_at, if_exists: true
    remove_column :captain_documents, :sync_claim_digest, if_exists: true

    remove_feedback_foreign_keys
    remove_check_constraint :captain_message_reports, name: 'chk_lla_message_reports_reason', if_exists: true
    remove_check_constraint :captain_message_reports, name: 'chk_lla_message_reports_description', if_exists: true
    remove_index :captain_message_reports, name: 'idx_lla_message_reports_effective', if_exists: true
    remove_index :captain_message_reports, name: 'idx_lla_message_reports_expiry', if_exists: true
    remove_index :messages, name: 'idx_lla_messages_feedback_tenant', if_exists: true
    remove_index :conversations, name: 'idx_lla_conversations_feedback_tenant', if_exists: true
    remove_column :captain_message_reports, :expires_at, if_exists: true
  end

  private

  def add_feedback_retention
    add_column :captain_message_reports, :expires_at, :datetime unless column_exists?(:captain_message_reports, :expires_at)
    execute <<~SQL.squish
      UPDATE captain_message_reports
      SET expires_at = created_at + INTERVAL '180 days',
          description = LEFT(description, 500)
      WHERE expires_at IS NULL OR char_length(description) > 500
    SQL
    change_column_null :captain_message_reports, :expires_at, false
  end

  def reconcile_feedback_tenancy
    execute <<~SQL.squish
      UPDATE captain_message_reports AS report
      SET account_id = message.account_id,
          conversation_id = message.conversation_id
      FROM messages AS message
      WHERE report.message_id = message.id
        AND (report.account_id <> message.account_id OR report.conversation_id <> message.conversation_id)
    SQL
  end

  def deduplicate_feedback
    execute <<~SQL.squish
      DELETE FROM captain_message_reports AS duplicate
      USING captain_message_reports AS keeper
      WHERE duplicate.account_id = keeper.account_id
        AND duplicate.user_id = keeper.user_id
        AND duplicate.message_id = keeper.message_id
        AND (duplicate.updated_at, duplicate.id) < (keeper.updated_at, keeper.id)
    SQL
  end

  def ensure_feedback_integrity!
    invalid = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM captain_message_reports AS report
      LEFT JOIN messages AS message
        ON message.id = report.message_id
       AND message.account_id = report.account_id
       AND message.conversation_id = report.conversation_id
      LEFT JOIN conversations AS conversation
        ON conversation.id = report.conversation_id
       AND conversation.account_id = report.account_id
      LEFT JOIN account_users AS membership
        ON membership.account_id = report.account_id
       AND membership.user_id = report.user_id
      WHERE message.id IS NULL OR conversation.id IS NULL OR membership.id IS NULL
    SQL
    return if invalid.zero?

    raise ActiveRecord::MigrationError,
          "#{invalid} captain message reports have orphaned or cross-tenant references; repair them before retrying"
  end

  def add_feedback_indexes
    add_index :captain_message_reports, %i[account_id user_id message_id],
              unique: true,
              name: 'idx_lla_message_reports_effective',
              algorithm: :concurrently,
              if_not_exists: true
    add_index :captain_message_reports, :expires_at,
              name: 'idx_lla_message_reports_expiry', algorithm: :concurrently, if_not_exists: true
    add_index :messages, %i[account_id id conversation_id],
              unique: true,
              name: 'idx_lla_messages_feedback_tenant',
              algorithm: :concurrently,
              if_not_exists: true
    add_index :conversations, %i[account_id id],
              unique: true,
              name: 'idx_lla_conversations_feedback_tenant',
              algorithm: :concurrently,
              if_not_exists: true
  end

  def add_feedback_constraints
    # Cast both sides to text. `varchar IN ('a', 'b')` is not a PostgreSQL deparse
    # fixed point: it comes back as ARRAY[...]::text[], which re-parses to
    # ARRAY['a'::character varying::text, ...], so `db/schema.rb` never settles.
    reasons = REPORT_REASONS.map { |reason| "#{connection.quote(reason)}::text" }.join(', ')
    add_check_constraint :captain_message_reports, "report_reason::text IN (#{reasons})",
                         name: 'chk_lla_message_reports_reason', validate: false, if_not_exists: true
    add_check_constraint :captain_message_reports, 'description IS NULL OR char_length(description) <= 500',
                         name: 'chk_lla_message_reports_description', validate: false, if_not_exists: true
    validate_check_constraint :captain_message_reports, name: 'chk_lla_message_reports_reason'
    validate_check_constraint :captain_message_reports, name: 'chk_lla_message_reports_description'
  end

  def add_feedback_foreign_keys
    add_validated_foreign_key :captain_message_reports, :messages,
                              column: %i[account_id message_id conversation_id],
                              primary_key: %i[account_id id conversation_id],
                              name: 'fk_lla_message_reports_message_tenant', on_delete: :cascade
    add_validated_foreign_key :captain_message_reports, :conversations,
                              column: %i[account_id conversation_id], primary_key: %i[account_id id],
                              name: 'fk_lla_message_reports_conversation_tenant', on_delete: :cascade
    add_validated_foreign_key :captain_message_reports, :account_users,
                              column: %i[account_id user_id], primary_key: %i[account_id user_id],
                              name: 'fk_lla_message_reports_membership', on_delete: :cascade
  end

  def add_validated_foreign_key(from_table, to_table, **options)
    add_foreign_key from_table, to_table, **options, validate: false, if_not_exists: true
    validate_foreign_key from_table, name: options.fetch(:name)
  end

  def remove_feedback_foreign_keys
    %w[
      fk_lla_message_reports_message_tenant
      fk_lla_message_reports_conversation_tenant
      fk_lla_message_reports_membership
    ].each do |name|
      remove_foreign_key :captain_message_reports, name: name, if_exists: true
    end
  end

  def add_document_sync_claims
    add_column :captain_documents, :sync_claim_digest, :string unless column_exists?(:captain_documents, :sync_claim_digest)
    add_column :captain_documents, :sync_claimed_at, :datetime unless column_exists?(:captain_documents, :sync_claimed_at)
  end

  # rubocop:disable Metrics/MethodLength
  def create_bulk_operations
    unless table_exists?(:lla_captain_bulk_operations)
      create_table :lla_captain_bulk_operations do |t|
        t.references :account, null: false, foreign_key: { on_delete: :cascade }
        t.references :user, null: false, foreign_key: { on_delete: :cascade }
        t.string :key_digest, null: false
        t.string :request_digest, null: false
        t.string :resource_type, null: false
        t.string :action, null: false
        t.string :state, null: false, default: 'pending'
        t.integer :requested_count, null: false, default: 0
        t.integer :processed_count, null: false, default: 0
        t.integer :error_count, null: false, default: 0
        t.jsonb :result, null: false, default: {}
        t.datetime :started_at
        t.datetime :completed_at
        t.datetime :expires_at, null: false
        t.timestamps
      end
    end

    add_index :lla_captain_bulk_operations, %i[account_id key_digest],
              unique: true,
              name: 'idx_lla_bulk_operations_idempotency',
              if_not_exists: true
    add_index :lla_captain_bulk_operations, :expires_at,
              name: 'idx_lla_bulk_operations_expiry',
              if_not_exists: true
    add_check_constraint :lla_captain_bulk_operations,
                         "state::text IN ('pending'::text, 'processing'::text, 'completed'::text, 'failed'::text)",
                         name: 'chk_lla_bulk_operations_state',
                         if_not_exists: true
    add_check_constraint :lla_captain_bulk_operations,
                         'char_length(key_digest) = 64 AND char_length(request_digest) = 64',
                         name: 'chk_lla_bulk_operations_digests',
                         if_not_exists: true
    add_check_constraint :lla_captain_bulk_operations,
                         'requested_count BETWEEN 1 AND 100 AND processed_count BETWEEN 0 AND requested_count ' \
                         'AND error_count BETWEEN 0 AND requested_count ' \
                         'AND processed_count + error_count <= requested_count',
                         name: 'chk_lla_bulk_operations_counts',
                         if_not_exists: true
    add_foreign_key :lla_captain_bulk_operations, :account_users,
                    column: %i[account_id user_id], primary_key: %i[account_id user_id],
                    name: 'fk_lla_bulk_operations_membership', on_delete: :cascade,
                    if_not_exists: true
  end
  # rubocop:enable Metrics/MethodLength
end
# rubocop:enable Metrics/ClassLength
