class HardenCaptainAgentAndCopilotBoundaries < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    backfill_unambiguous_copilot_assistants
    ensure_no_missing_copilot_assistants!

    add_boundary_indexes
    add_boundary_constraints
    add_boundary_foreign_keys

    change_column_null :copilot_threads, :assistant_id, false
  end

  def down
    change_column_null :copilot_threads, :assistant_id, true

    remove_foreign_keys
    remove_check_constraint :agent_sessions, name: 'chk_lla_agent_sessions_type'
    remove_check_constraint :copilot_messages, name: 'chk_lla_copilot_messages_type'

    remove_index :agent_sessions, name: 'idx_lla_agent_sessions_unique_result'
    remove_index :agent_sessions, name: 'idx_lla_agent_sessions_assistant_recent'
    remove_index :copilot_messages, name: 'idx_lla_copilot_messages_thread_order'
    remove_index :copilot_threads, name: 'idx_lla_copilot_threads_owner_recent'
  end

  private

  def backfill_unambiguous_copilot_assistants
    execute <<~SQL.squish
      UPDATE copilot_threads AS thread
      SET assistant_id = candidate.assistant_id
      FROM (
        SELECT account_id, MIN(id) AS assistant_id
        FROM captain_assistants
        GROUP BY account_id
        HAVING COUNT(*) = 1
      ) AS candidate
      WHERE thread.assistant_id IS NULL
        AND thread.account_id = candidate.account_id
    SQL
  end

  def ensure_no_missing_copilot_assistants!
    missing = select_value('SELECT COUNT(*) FROM copilot_threads WHERE assistant_id IS NULL').to_i
    return if missing.zero?

    raise ActiveRecord::MigrationError,
          "#{missing} copilot_threads have no unambiguous assistant; assign an account-owned assistant before retrying"
  end

  def add_boundary_indexes
    add_index :copilot_threads, %i[account_id user_id created_at],
              algorithm: :concurrently, name: 'idx_lla_copilot_threads_owner_recent'
    add_index :copilot_messages, %i[copilot_thread_id created_at id],
              algorithm: :concurrently, name: 'idx_lla_copilot_messages_thread_order'
    add_index :agent_sessions, %i[account_id assistant_id created_at],
              algorithm: :concurrently, name: 'idx_lla_agent_sessions_assistant_recent'
    add_index :agent_sessions, %i[account_id result_type result_id],
              unique: true, where: 'result_id IS NOT NULL', algorithm: :concurrently,
              name: 'idx_lla_agent_sessions_unique_result'
  end

  def add_boundary_constraints
    add_check_constraint :agent_sessions, 'session_type IN (0, 1)',
                         name: 'chk_lla_agent_sessions_type', validate: false
    add_check_constraint :copilot_messages, 'message_type IN (0, 1, 2)',
                         name: 'chk_lla_copilot_messages_type', validate: false

    validate_check_constraint :agent_sessions, name: 'chk_lla_agent_sessions_type'
    validate_check_constraint :copilot_messages, name: 'chk_lla_copilot_messages_type'
  end

  def add_boundary_foreign_keys
    add_validated_foreign_key :agent_sessions, :accounts, column: :account_id, name: 'fk_lla_agent_sessions_account'
    add_validated_foreign_key :agent_sessions, :captain_assistants,
                              column: :assistant_id, name: 'fk_lla_agent_sessions_assistant'
    add_validated_foreign_key :agent_sessions, :users, column: :user_id, name: 'fk_lla_agent_sessions_user'

    add_validated_foreign_key :captain_scenarios, :accounts, column: :account_id, name: 'fk_lla_scenarios_account'
    add_validated_foreign_key :captain_scenarios, :captain_assistants,
                              column: :assistant_id, name: 'fk_lla_scenarios_assistant'

    add_validated_foreign_key :copilot_threads, :accounts, column: :account_id, name: 'fk_lla_copilot_threads_account'
    add_validated_foreign_key :copilot_threads, :captain_assistants,
                              column: :assistant_id, name: 'fk_lla_copilot_threads_assistant'
    add_validated_foreign_key :copilot_threads, :users, column: :user_id, name: 'fk_lla_copilot_threads_user'

    add_validated_foreign_key :copilot_messages, :accounts, column: :account_id, name: 'fk_lla_copilot_messages_account'
    add_validated_foreign_key :copilot_messages, :copilot_threads,
                              column: :copilot_thread_id, name: 'fk_lla_copilot_messages_thread'
  end

  def add_validated_foreign_key(from_table, to_table, column:, name:)
    add_foreign_key from_table, to_table, column: column, name: name, validate: false
    validate_foreign_key from_table, name: name
  end

  def remove_foreign_keys
    {
      agent_sessions: %w[fk_lla_agent_sessions_account fk_lla_agent_sessions_assistant fk_lla_agent_sessions_user],
      captain_scenarios: %w[fk_lla_scenarios_account fk_lla_scenarios_assistant],
      copilot_threads: %w[fk_lla_copilot_threads_account fk_lla_copilot_threads_assistant fk_lla_copilot_threads_user],
      copilot_messages: %w[fk_lla_copilot_messages_account fk_lla_copilot_messages_thread]
    }.each do |table, names|
      names.each { |name| remove_foreign_key table, name: name }
    end
  end
end
