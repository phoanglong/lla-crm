# frozen_string_literal: true

class CreateLlaKnowledgeGenerationFoundations < ActiveRecord::Migration[7.1]
  def up
    add_tenant_identity_indexes
    create_generation_operations
    create_generation_items
    create_generation_outboxes
  end

  def down
    drop_table :lla_knowledge_generation_outboxes, if_exists: true
    drop_table :lla_knowledge_generation_items, if_exists: true
    drop_table :lla_knowledge_generation_operations, if_exists: true
    remove_index :articles, name: 'idx_lla_articles_tenant_identity', if_exists: true
    remove_index :categories, name: 'idx_lla_categories_tenant_identity', if_exists: true
    remove_index :portals, name: 'idx_lla_portals_tenant_identity', if_exists: true
  end

  private

  def add_tenant_identity_indexes
    add_index :portals, %i[account_id id], unique: true,
                                           name: 'idx_lla_portals_tenant_identity', if_not_exists: true
    add_index :categories, %i[account_id portal_id id], unique: true,
                                                        name: 'idx_lla_categories_tenant_identity', if_not_exists: true
    add_index :articles, %i[account_id portal_id id], unique: true,
                                                      name: 'idx_lla_articles_tenant_identity', if_not_exists: true
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def create_generation_operations
    create_table :lla_knowledge_generation_operations do |t|
      t.bigint :account_id, null: false
      t.bigint :portal_id, null: false
      t.bigint :user_id, null: false
      t.string :operation_type, null: false, limit: 32, default: 'onboarding'
      t.string :state, null: false, limit: 32, default: 'pending'
      t.string :idempotency_digest, null: false, limit: 64
      t.string :request_digest, null: false, limit: 64
      t.string :consent_digest, limit: 64
      t.string :claim_digest, limit: 64
      t.integer :version, null: false, default: 1
      t.integer :expected_items, null: false, default: 0
      t.integer :finished_items, null: false, default: 0
      t.integer :failed_items, null: false, default: 0
      t.integer :max_items, null: false, default: 25
      t.integer :max_source_urls, null: false, default: 75
      t.integer :max_attempts, null: false, default: 3
      t.string :last_error_code, limit: 80
      t.datetime :claimed_at
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :cancelled_at
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :lla_knowledge_generation_operations, %i[account_id portal_id idempotency_digest],
              unique: true, name: 'idx_lla_knowledge_operations_idempotency'
    add_index :lla_knowledge_generation_operations, %i[account_id portal_id id],
              unique: true, name: 'idx_lla_knowledge_operations_tenant_identity'
    add_index :lla_knowledge_generation_operations, %i[state created_at],
              name: 'idx_lla_knowledge_operations_state'
    add_index :lla_knowledge_generation_operations, :expires_at,
              name: 'idx_lla_knowledge_operations_expiry'

    add_foreign_key :lla_knowledge_generation_operations, :accounts, on_delete: :cascade
    add_foreign_key :lla_knowledge_generation_operations, :portals,
                    column: %i[account_id portal_id], primary_key: %i[account_id id],
                    name: 'fk_lla_knowledge_operations_portal_tenant', on_delete: :cascade
    add_foreign_key :lla_knowledge_generation_operations, :account_users,
                    column: %i[account_id user_id], primary_key: %i[account_id user_id],
                    name: 'fk_lla_knowledge_operations_membership', on_delete: :cascade

    add_check_constraint :lla_knowledge_generation_operations,
                         "operation_type IN ('onboarding', 'translation', 'reindex')",
                         name: 'chk_lla_knowledge_operations_type'
    add_check_constraint :lla_knowledge_generation_operations,
                         "state IN ('pending', 'planning', 'dispatching', 'running', 'completed', " \
                         "'completed_with_errors', 'skipped', 'failed', 'cancelled')",
                         name: 'chk_lla_knowledge_operations_state'
    add_check_constraint :lla_knowledge_generation_operations,
                         'char_length(idempotency_digest) = 64 AND char_length(request_digest) = 64 ' \
                         'AND (consent_digest IS NULL OR char_length(consent_digest) = 64) ' \
                         'AND (claim_digest IS NULL OR char_length(claim_digest) = 64)',
                         name: 'chk_lla_knowledge_operations_digests'
    add_check_constraint :lla_knowledge_generation_operations,
                         'version > 0 AND expected_items BETWEEN 0 AND max_items ' \
                         'AND finished_items BETWEEN 0 AND expected_items ' \
                         'AND failed_items BETWEEN 0 AND finished_items ' \
                         'AND max_items BETWEEN 1 AND 25 AND max_source_urls BETWEEN 1 AND 75 ' \
                         'AND max_attempts BETWEEN 1 AND 5',
                         name: 'chk_lla_knowledge_operations_bounds'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # rubocop:disable Metrics/MethodLength
  def create_generation_items
    create_table :lla_knowledge_generation_items do |t|
      t.bigint :account_id, null: false
      t.bigint :portal_id, null: false
      t.bigint :generation_operation_id, null: false
      t.bigint :category_id
      t.bigint :article_id
      t.integer :ordinal, null: false
      t.string :state, null: false, limit: 24, default: 'pending'
      t.string :item_key_digest, null: false, limit: 64
      t.string :source_digest, null: false, limit: 64
      t.string :claim_digest, limit: 64
      t.string :last_error_code, limit: 80
      t.integer :attempts, null: false, default: 0
      t.datetime :claimed_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :lla_knowledge_generation_items, %i[generation_operation_id ordinal],
              unique: true, name: 'idx_lla_knowledge_items_ordinal'
    add_index :lla_knowledge_generation_items, %i[generation_operation_id item_key_digest],
              unique: true, name: 'idx_lla_knowledge_items_idempotency'
    add_index :lla_knowledge_generation_items, %i[state updated_at], name: 'idx_lla_knowledge_items_state'

    add_foreign_key :lla_knowledge_generation_items, :lla_knowledge_generation_operations,
                    column: %i[account_id portal_id generation_operation_id],
                    primary_key: %i[account_id portal_id id],
                    name: 'fk_lla_knowledge_items_operation_tenant', on_delete: :cascade
    add_foreign_key :lla_knowledge_generation_items, :categories,
                    name: 'fk_lla_knowledge_items_category', on_delete: :nullify
    add_foreign_key :lla_knowledge_generation_items, :articles,
                    name: 'fk_lla_knowledge_items_article', on_delete: :nullify

    add_check_constraint :lla_knowledge_generation_items,
                         "state IN ('pending', 'claimed', 'succeeded', 'failed', 'cancelled')",
                         name: 'chk_lla_knowledge_items_state'
    add_check_constraint :lla_knowledge_generation_items,
                         'ordinal >= 0 AND attempts BETWEEN 0 AND 5',
                         name: 'chk_lla_knowledge_items_bounds'
    add_check_constraint :lla_knowledge_generation_items,
                         'char_length(item_key_digest) = 64 AND char_length(source_digest) = 64 ' \
                         'AND (claim_digest IS NULL OR char_length(claim_digest) = 64)',
                         name: 'chk_lla_knowledge_items_digests'
  end
  # rubocop:enable Metrics/MethodLength

  # rubocop:disable Metrics/MethodLength
  def create_generation_outboxes
    create_table :lla_knowledge_generation_outboxes do |t|
      t.bigint :account_id, null: false
      t.bigint :portal_id, null: false
      t.bigint :generation_operation_id, null: false
      t.string :event_type, null: false, limit: 48
      t.string :state, null: false, limit: 16, default: 'pending'
      t.string :idempotency_digest, null: false, limit: 64
      t.string :payload_digest, null: false, limit: 64
      t.text :payload_ciphertext
      t.string :claim_digest, limit: 64
      t.string :last_error_code, limit: 80
      t.integer :attempts, null: false, default: 0
      t.datetime :available_at, null: false
      t.datetime :claimed_at
      t.datetime :delivered_at
      t.timestamps
    end

    add_index :lla_knowledge_generation_outboxes, %i[generation_operation_id idempotency_digest],
              unique: true, name: 'idx_lla_knowledge_outboxes_idempotency'
    add_index :lla_knowledge_generation_outboxes, %i[state available_at],
              name: 'idx_lla_knowledge_outboxes_ready'
    add_foreign_key :lla_knowledge_generation_outboxes, :lla_knowledge_generation_operations,
                    column: %i[account_id portal_id generation_operation_id],
                    primary_key: %i[account_id portal_id id],
                    name: 'fk_lla_knowledge_outboxes_operation_tenant', on_delete: :cascade
    add_check_constraint :lla_knowledge_generation_outboxes,
                         "state IN ('pending', 'claimed', 'delivered', 'failed', 'cancelled')",
                         name: 'chk_lla_knowledge_outboxes_state'
    add_check_constraint :lla_knowledge_generation_outboxes,
                         'attempts BETWEEN 0 AND 5', name: 'chk_lla_knowledge_outboxes_attempts'
    add_check_constraint :lla_knowledge_generation_outboxes,
                         'char_length(idempotency_digest) = 64 AND char_length(payload_digest) = 64 ' \
                         'AND (claim_digest IS NULL OR char_length(claim_digest) = 64)',
                         name: 'chk_lla_knowledge_outboxes_digests'
  end
  # rubocop:enable Metrics/MethodLength
end
