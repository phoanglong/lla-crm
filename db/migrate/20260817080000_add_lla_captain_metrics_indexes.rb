# frozen_string_literal: true

class AddLlaCaptainMetricsIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    add_index :messages,
              %i[account_id sender_id created_at conversation_id],
              name: 'idx_lla_captain_messages_metrics',
              where: "sender_type = 'Captain::Assistant'",
              algorithm: :concurrently,
              if_not_exists: true

    add_index :reporting_events,
              %i[account_id name created_at conversation_id],
              name: 'idx_lla_captain_reporting_metrics',
              algorithm: :concurrently,
              if_not_exists: true

    add_index :reporting_events,
              %i[account_id event_end_time conversation_id],
              name: 'idx_lla_captain_reopen_metrics',
              where: "name = 'conversation_opened' AND event_end_time IS NOT NULL",
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :reporting_events, name: 'idx_lla_captain_reopen_metrics', algorithm: :concurrently, if_exists: true
    remove_index :reporting_events, name: 'idx_lla_captain_reporting_metrics', algorithm: :concurrently, if_exists: true
    remove_index :messages, name: 'idx_lla_captain_messages_metrics', algorithm: :concurrently, if_exists: true
  end
end
