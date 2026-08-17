# frozen_string_literal: true

class HardenLlaKnowledgeGenerationPipeline < ActiveRecord::Migration[7.1]
  # rubocop:disable Metrics/MethodLength
  def up
    add_column :lla_knowledge_generation_operations, :provider_consent_digests,
               :jsonb, null: false, default: {}, if_not_exists: true

    add_index :lla_knowledge_generation_items, %i[generation_operation_id state],
              name: 'idx_lla_knowledge_items_operation_state', if_not_exists: true
    add_index :lla_knowledge_generation_items, %i[state claimed_at],
              name: 'idx_lla_knowledge_items_stale_claims', if_not_exists: true
    add_index :lla_knowledge_generation_items, :article_id,
              unique: true, where: 'article_id IS NOT NULL',
              name: 'idx_lla_knowledge_items_article_result', if_not_exists: true
    add_index :lla_knowledge_generation_outboxes, %i[event_type state available_at],
              name: 'idx_lla_knowledge_outboxes_dispatch', if_not_exists: true
    add_index :lla_knowledge_generation_outboxes, %i[state claimed_at],
              name: 'idx_lla_knowledge_outboxes_stale_claims', if_not_exists: true
    add_index :lla_knowledge_generation_operations, %i[state claimed_at],
              name: 'idx_lla_knowledge_operations_stale_claims', if_not_exists: true

    add_check_constraint :lla_knowledge_generation_operations,
                         "jsonb_typeof(provider_consent_digests) = 'object'",
                         name: 'chk_lla_knowledge_operations_provider_consents', if_not_exists: true
    add_check_constraint :lla_knowledge_generation_items,
                         "(state = 'succeeded' AND article_id IS NOT NULL) OR " \
                         "(state <> 'succeeded' AND article_id IS NULL)",
                         name: 'chk_lla_knowledge_items_result_state', if_not_exists: true
    add_check_constraint :lla_knowledge_generation_outboxes,
                         'char_length(payload_ciphertext) BETWEEN 40 AND 131072',
                         name: 'chk_lla_knowledge_outboxes_payload', if_not_exists: true
  end

  def down
    remove_check_constraint :lla_knowledge_generation_outboxes,
                            name: 'chk_lla_knowledge_outboxes_payload', if_exists: true
    remove_check_constraint :lla_knowledge_generation_items,
                            name: 'chk_lla_knowledge_items_result_state', if_exists: true
    remove_check_constraint :lla_knowledge_generation_operations,
                            name: 'chk_lla_knowledge_operations_provider_consents', if_exists: true
    remove_index :lla_knowledge_generation_outboxes,
                 name: 'idx_lla_knowledge_outboxes_stale_claims', if_exists: true
    remove_index :lla_knowledge_generation_operations,
                 name: 'idx_lla_knowledge_operations_stale_claims', if_exists: true
    remove_index :lla_knowledge_generation_outboxes,
                 name: 'idx_lla_knowledge_outboxes_dispatch', if_exists: true
    remove_index :lla_knowledge_generation_items,
                 name: 'idx_lla_knowledge_items_article_result', if_exists: true
    remove_index :lla_knowledge_generation_items,
                 name: 'idx_lla_knowledge_items_stale_claims', if_exists: true
    remove_index :lla_knowledge_generation_items,
                 name: 'idx_lla_knowledge_items_operation_state', if_exists: true
    remove_column :lla_knowledge_generation_operations, :provider_consent_digests,
                  if_exists: true
  end
  # rubocop:enable Metrics/MethodLength
end
