# frozen_string_literal: true

class HardenLlaArticleTranslationAndSearch < ActiveRecord::Migration[7.1]
  def up
    extend_generation_items
    add_article_search_state
    harden_article_embeddings
  end

  def down
    rollback_article_embeddings
    rollback_article_search_state
    rollback_generation_items
  end

  private

  def extend_generation_items
    add_column :lla_knowledge_generation_items, :item_type, :string,
               null: false, default: 'article_generation', limit: 32
    add_column :lla_knowledge_generation_items, :output_article_id, :bigint
    add_index :lla_knowledge_generation_items, :output_article_id,
              name: 'idx_lla_knowledge_items_output_article'
    add_foreign_key :lla_knowledge_generation_items, :articles,
                    column: :output_article_id, name: 'fk_lla_knowledge_items_output_article',
                    on_delete: :nullify

    remove_check_constraint :lla_knowledge_generation_items,
                            name: 'chk_lla_knowledge_items_result_state'
    add_check_constraint :lla_knowledge_generation_items, item_result_constraint,
                         name: 'chk_lla_knowledge_items_result_state'
    add_check_constraint :lla_knowledge_generation_items,
                         "item_type IN ('article_generation', 'translation', 'reindex')",
                         name: 'chk_lla_knowledge_items_type'
  end

  def add_article_search_state # rubocop:disable Metrics/MethodLength
    add_column :articles, :lla_search_content_digest, :string, limit: 64
    add_column :articles, :lla_search_version, :integer, null: false, default: 1
    add_column :articles, :lla_search_active_version, :integer, null: false, default: 0
    add_column :articles, :lla_search_embedding_model, :string, limit: 100
    add_column :articles, :lla_search_embedding_dimensions, :integer

    execute <<~SQL.squish
      UPDATE articles
         SET lla_search_content_digest =
               md5(concat_ws('|lla|', title, description, content)) ||
               md5(concat_ws('|lla|', 'lla-search', title, description, content))
    SQL
    change_column_null :articles, :lla_search_content_digest, false

    add_index :articles, %i[portal_id associated_article_id locale],
              unique: true, where: 'associated_article_id IS NOT NULL',
              name: 'idx_lla_articles_unique_translation'
    add_check_constraint :articles,
                         'char_length(lla_search_content_digest) = 64',
                         name: 'chk_lla_articles_search_digest'
    add_check_constraint :articles,
                         'lla_search_version >= 1 AND lla_search_active_version >= 0 ' \
                         'AND lla_search_active_version <= lla_search_version',
                         name: 'chk_lla_articles_search_versions'
    add_check_constraint :articles,
                         '(lla_search_embedding_dimensions IS NULL AND lla_search_embedding_model IS NULL) OR ' \
                         '(lla_search_embedding_dimensions = 1536 AND char_length(lla_search_embedding_model) BETWEEN 3 AND 100)',
                         name: 'chk_lla_articles_search_profile'
  end # rubocop:enable Metrics/MethodLength

  # rubocop:disable Metrics/MethodLength
  def harden_article_embeddings
    execute <<~SQL.squish
      DELETE FROM article_embeddings embeddings
       WHERE embeddings.embedding IS NULL
          OR NOT EXISTS (SELECT 1 FROM articles WHERE articles.id = embeddings.article_id)
    SQL

    add_column :article_embeddings, :account_id, :bigint
    add_column :article_embeddings, :portal_id, :bigint
    add_column :article_embeddings, :model, :string, limit: 100
    add_column :article_embeddings, :dimensions, :integer
    add_column :article_embeddings, :content_digest, :string, limit: 64
    add_column :article_embeddings, :term_digest, :string, limit: 64
    add_column :article_embeddings, :index_version, :integer
    add_column :article_embeddings, :active, :boolean, null: false, default: false

    execute <<~SQL.squish
      UPDATE article_embeddings embeddings
         SET account_id = articles.account_id,
             portal_id = articles.portal_id,
             model = 'legacy-unverified',
             dimensions = 1536,
             content_digest = articles.lla_search_content_digest,
             term_digest = md5(embeddings.term) || md5('lla-term:' || embeddings.term),
             index_version = 1,
             active = FALSE
        FROM articles
       WHERE articles.id = embeddings.article_id
    SQL

    %i[account_id portal_id model dimensions content_digest term_digest index_version].each do |column|
      change_column_null :article_embeddings, column, false
    end

    remove_index :article_embeddings, name: 'index_article_embeddings_on_embedding', if_exists: true
    add_index :article_embeddings, :embedding, using: :ivfflat,
                                               opclass: :vector_cosine_ops,
                                               name: 'idx_lla_article_embeddings_cosine'
    add_index :article_embeddings, %i[article_id model index_version term_digest], unique: true,
                                                                                   name: 'idx_lla_article_embeddings_version_term'
    add_index :article_embeddings, %i[account_id portal_id active model],
              name: 'idx_lla_article_embeddings_active_scope'
    add_index :article_embeddings, %i[article_id active index_version],
              name: 'idx_lla_article_embeddings_article_active'

    add_foreign_key :article_embeddings, :articles,
                    column: %i[account_id portal_id article_id], primary_key: %i[account_id portal_id id],
                    name: 'fk_lla_article_embeddings_article_tenant', on_delete: :cascade
    add_check_constraint :article_embeddings,
                         'dimensions = 1536 AND index_version >= 1 AND embedding IS NOT NULL ' \
                         'AND vector_dims(embedding) = dimensions',
                         name: 'chk_lla_article_embeddings_profile'
    add_check_constraint :article_embeddings,
                         'char_length(content_digest) = 64 AND char_length(term_digest) = 64',
                         name: 'chk_lla_article_embeddings_digests'
  end
  # rubocop:enable Metrics/MethodLength

  def rollback_article_embeddings
    remove_check_constraint :article_embeddings, name: 'chk_lla_article_embeddings_digests'
    remove_check_constraint :article_embeddings, name: 'chk_lla_article_embeddings_profile'
    remove_foreign_key :article_embeddings, name: 'fk_lla_article_embeddings_article_tenant'
    remove_index :article_embeddings, name: 'idx_lla_article_embeddings_article_active'
    remove_index :article_embeddings, name: 'idx_lla_article_embeddings_active_scope'
    remove_index :article_embeddings, name: 'idx_lla_article_embeddings_version_term'
    remove_index :article_embeddings, name: 'idx_lla_article_embeddings_cosine'
    add_index :article_embeddings, :embedding, using: :ivfflat,
                                               opclass: :vector_l2_ops,
                                               name: 'index_article_embeddings_on_embedding'
    remove_columns :article_embeddings, :account_id, :portal_id, :model, :dimensions,
                   :content_digest, :term_digest, :index_version, :active
  end

  def rollback_article_search_state
    remove_check_constraint :articles, name: 'chk_lla_articles_search_profile'
    remove_check_constraint :articles, name: 'chk_lla_articles_search_versions'
    remove_check_constraint :articles, name: 'chk_lla_articles_search_digest'
    remove_index :articles, name: 'idx_lla_articles_unique_translation'
    remove_columns :articles, :lla_search_content_digest, :lla_search_version,
                   :lla_search_active_version, :lla_search_embedding_model,
                   :lla_search_embedding_dimensions
  end

  def rollback_generation_items
    execute <<~SQL.squish
      DELETE FROM lla_knowledge_generation_operations
       WHERE operation_type IN ('translation', 'reindex')
    SQL
    remove_check_constraint :lla_knowledge_generation_items, name: 'chk_lla_knowledge_items_type'
    remove_check_constraint :lla_knowledge_generation_items,
                            name: 'chk_lla_knowledge_items_result_state'
    add_check_constraint :lla_knowledge_generation_items,
                         "(state = 'succeeded' AND article_id IS NOT NULL) OR " \
                         "(state <> 'succeeded' AND article_id IS NULL)",
                         name: 'chk_lla_knowledge_items_result_state'
    remove_foreign_key :lla_knowledge_generation_items, name: 'fk_lla_knowledge_items_output_article'
    remove_index :lla_knowledge_generation_items, name: 'idx_lla_knowledge_items_output_article'
    remove_columns :lla_knowledge_generation_items, :output_article_id, :item_type
  end

  def item_result_constraint
    <<~SQL.squish
      (
        state = 'succeeded' AND (
          (item_type = 'article_generation' AND article_id IS NOT NULL AND output_article_id IS NULL) OR
          (item_type = 'translation' AND article_id IS NULL AND output_article_id IS NOT NULL) OR
          (item_type = 'reindex' AND article_id IS NULL AND output_article_id IS NULL)
        )
      ) OR (
        state <> 'succeeded' AND article_id IS NULL AND output_article_id IS NULL
      )
    SQL
  end
end
