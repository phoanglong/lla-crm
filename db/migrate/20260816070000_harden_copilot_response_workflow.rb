# frozen_string_literal: true

class HardenCopilotResponseWorkflow < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    add_response_columns
    add_response_indexes
    add_response_constraints
  end

  def down
    remove_response_constraints
    remove_response_indexes

    remove_column :copilot_messages, :source_message_id
    remove_column :copilot_messages, :response_completed_at
    remove_column :copilot_messages, :response_reserved_at
    remove_column :copilot_messages, :response_attempts
    remove_column :copilot_messages, :response_job_token
    remove_column :copilot_messages, :response_state
    remove_column :copilot_messages, :conversation_id
  end

  private

  def add_response_columns
    add_column :copilot_messages, :conversation_id, :bigint
    add_column :copilot_messages, :response_state, :integer, null: false, default: 0
    add_column :copilot_messages, :response_job_token, :uuid
    add_column :copilot_messages, :response_attempts, :integer, null: false, default: 0
    add_column :copilot_messages, :response_reserved_at, :datetime
    add_column :copilot_messages, :response_completed_at, :datetime
    add_column :copilot_messages, :source_message_id, :bigint
  end

  def add_response_indexes
    add_index :copilot_messages, :conversation_id, algorithm: :concurrently, name: 'idx_lla_copilot_messages_conversation'
    add_index :copilot_messages, %i[copilot_thread_id response_state id], algorithm: :concurrently,
                                                                          name: 'idx_lla_copilot_thread_response_order'
    add_index :copilot_messages, :response_job_token, unique: true, where: 'response_job_token IS NOT NULL',
                                                      algorithm: :concurrently, name: 'idx_lla_copilot_response_token'
    add_index :copilot_messages, :source_message_id, unique: true,
                                                     where: 'message_type = 1 AND source_message_id IS NOT NULL',
                                                     algorithm: :concurrently, name: 'idx_lla_copilot_final_response'
  end

  def add_response_constraints
    add_response_check_constraints
    validate_response_check_constraints
    add_response_foreign_keys
  end

  def add_response_check_constraints
    add_check_constraint :copilot_messages, 'response_state IN (0, 1, 2, 3, 4)',
                         name: 'chk_lla_copilot_response_state', validate: false
    add_check_constraint :copilot_messages, 'response_attempts >= 0',
                         name: 'chk_lla_copilot_response_attempts', validate: false
    add_check_constraint :copilot_messages,
                         '(response_state = 0 AND response_job_token IS NULL) OR ' \
                         '(response_state IN (1, 2, 3, 4) AND response_job_token IS NOT NULL)',
                         name: 'chk_lla_copilot_response_token', validate: false
    add_check_constraint :copilot_messages, 'response_state = 0 OR message_type = 0',
                         name: 'chk_lla_copilot_response_owner', validate: false
    add_check_constraint :copilot_messages, 'source_message_id IS NULL OR message_type IN (1, 2)',
                         name: 'chk_lla_copilot_response_source_type', validate: false
  end

  def validate_response_check_constraints
    validate_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_state'
    validate_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_attempts'
    validate_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_token'
    validate_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_owner'
    validate_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_source_type'
  end

  def add_response_foreign_keys
    add_foreign_key :copilot_messages, :conversations, column: :conversation_id,
                                                       name: 'fk_lla_copilot_messages_conversation', validate: false
    add_foreign_key :copilot_messages, :copilot_messages, column: :source_message_id,
                                                          name: 'fk_lla_copilot_messages_source', validate: false
    validate_foreign_key :copilot_messages, name: 'fk_lla_copilot_messages_conversation'
    validate_foreign_key :copilot_messages, name: 'fk_lla_copilot_messages_source'
  end

  def remove_response_constraints
    remove_foreign_key :copilot_messages, name: 'fk_lla_copilot_messages_source', if_exists: true
    remove_foreign_key :copilot_messages, name: 'fk_lla_copilot_messages_conversation', if_exists: true
    remove_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_source_type', if_exists: true
    remove_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_owner', if_exists: true
    remove_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_token', if_exists: true
    remove_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_attempts', if_exists: true
    remove_check_constraint :copilot_messages, name: 'chk_lla_copilot_response_state', if_exists: true
  end

  def remove_response_indexes
    remove_index :copilot_messages, name: 'idx_lla_copilot_final_response', if_exists: true
    remove_index :copilot_messages, name: 'idx_lla_copilot_response_token', if_exists: true
    remove_index :copilot_messages, name: 'idx_lla_copilot_thread_response_order', if_exists: true
    remove_index :copilot_messages, name: 'idx_lla_copilot_messages_conversation', if_exists: true
  end
end
