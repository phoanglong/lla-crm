class AddFingerprintsToCaptainFaqMemory < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_column :captain_faq_suggestions, :content_fingerprint, :string
    add_column :captain_faq_observations, :source_fingerprint, :string

    add_index :captain_faq_suggestions,
              %i[account_id assistant_id language content_fingerprint],
              unique: true,
              where: 'content_fingerprint IS NOT NULL',
              algorithm: :concurrently,
              name: 'idx_cap_faq_suggestions_unique_content'
    add_index :captain_faq_observations,
              %i[account_id conversation_id source_fingerprint],
              unique: true,
              where: 'source_fingerprint IS NOT NULL',
              algorithm: :concurrently,
              name: 'idx_cap_faq_observations_unique_source'
  end
end
