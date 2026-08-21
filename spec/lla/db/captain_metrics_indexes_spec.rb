require 'rails_helper'

RSpec.describe 'LLA Captain metrics indexes', type: :model do
  def index_for(table, name)
    ActiveRecord::Base.connection.indexes(table).find { |index| index.name == name }
  end

  it 'covers assistant messages by tenant, sender, time and conversation' do
    index = index_for(:messages, 'idx_lla_captain_messages_metrics')

    expect(index&.columns).to eq(%w[account_id sender_id created_at conversation_id])
    expect(index&.where).to include('Captain::Assistant')
  end

  it 'covers resolution and handoff events by tenant, name, time and conversation' do
    index = index_for(:reporting_events, 'idx_lla_captain_reporting_metrics')

    expect(index&.columns).to eq(%w[account_id name created_at conversation_id])
  end

  it 'covers reopen events by tenant, event time and conversation' do
    index = index_for(:reporting_events, 'idx_lla_captain_reopen_metrics')

    expect(index&.columns).to eq(%w[account_id event_end_time conversation_id])
    expect(index&.where).to include('conversation_opened', 'event_end_time IS NOT NULL')
  end
end
