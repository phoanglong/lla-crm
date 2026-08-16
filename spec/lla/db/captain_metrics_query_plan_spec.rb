require 'rails_helper'

RSpec.describe 'LLA Captain metrics query plans', type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:connection) { ActiveRecord::Base.connection }

  before do
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     sender: assistant, message_type: :outgoing, created_at: 1.day.ago)
    create(:reporting_event, account: account, inbox: inbox, conversation: conversation,
                             name: 'conversation_bot_resolved', created_at: 1.day.ago)
    create(:reporting_event, account: account, inbox: inbox, conversation: conversation,
                             name: 'conversation_opened', value: 60, created_at: 1.day.ago,
                             event_start_time: 2.days.ago, event_end_time: 1.day.ago)
    insert_noise_rows
    connection.execute('ANALYZE messages')
    connection.execute('ANALYZE reporting_events')
  end

  it 'uses the bounded assistant-message index at target volume' do
    sql = Message.where(
      account_id: account.id,
      sender_type: 'Captain::Assistant',
      sender_id: assistant.id,
      created_at: 30.days.ago...Time.current
    ).select(:conversation_id).to_sql

    expect(explain(sql)).to include('idx_lla_captain_messages_metrics')
  end

  it 'uses an indexed reporting-event plan without a full table scan at target volume' do
    sql = ReportingEvent.where(
      account_id: account.id,
      name: Captain::AssistantStatsBuilder::RESOLVED_EVENT_NAMES,
      created_at: 30.days.ago...Time.current
    ).select(:conversation_id).to_sql

    plan = explain(sql)

    expect(plan).to include('"Node Type": "Index Scan"')
    expect(plan).not_to include('"Node Type": "Seq Scan"')
  end

  it 'uses the partial reopen index at target volume' do
    sql = ReportingEvent.where(account_id: account.id, name: 'conversation_opened')
                        .where(event_end_time: ...Time.current)
                        .select(:conversation_id).to_sql

    expect(explain(sql)).to include('idx_lla_captain_reopen_metrics')
  end

  private

  def explain(sql)
    connection.select_value("EXPLAIN (ANALYZE, FORMAT JSON) #{sql}")
  end

  def insert_noise_rows
    connection.execute(<<~SQL.squish)
      INSERT INTO messages
        (account_id, inbox_id, conversation_id, message_type, created_at, updated_at,
         private, content_type, sender_type, sender_id, external_source_ids, additional_attributes)
      SELECT
        #{account.id}, #{inbox.id}, #{conversation.id}, 1,
        CURRENT_TIMESTAMP - INTERVAL '400 days', CURRENT_TIMESTAMP - INTERVAL '400 days',
        FALSE, 0, 'Captain::Assistant', #{assistant.id} + series, '{}'::jsonb, '{}'::jsonb
      FROM generate_series(1, 10000) AS series
    SQL
    connection.execute(<<~SQL.squish)
      INSERT INTO reporting_events
        (account_id, inbox_id, conversation_id, name, value, created_at, updated_at,
         event_start_time, event_end_time)
      SELECT
        #{account.id} + series, #{inbox.id}, #{conversation.id}, 'conversation_bot_resolved', 0,
        CURRENT_TIMESTAMP - INTERVAL '1 day', CURRENT_TIMESTAMP - INTERVAL '1 day',
        CURRENT_TIMESTAMP - INTERVAL '2 days', CURRENT_TIMESTAMP - INTERVAL '1 day'
      FROM generate_series(1, 10000) AS series
    SQL
  end
end
