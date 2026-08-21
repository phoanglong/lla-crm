require 'rails_helper'

RSpec.describe Captain::AssistantDrilldownBuilder do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:authorized_scope) { account.conversations.where(id: authorized_conversation.id) }
  let(:authorized_conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:hidden_conversation) { create(:conversation, account: account, inbox: inbox) }

  before do
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    [authorized_conversation, hidden_conversation].each do |conversation|
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       sender: assistant, message_type: :outgoing, private: false, created_at: 5.days.ago,
                       content: 'must not leave the analytics endpoint')
    end
  end

  it 'returns the exact authorized cohort counted by the metric card' do
    metrics = Captain::AssistantStatsBuilder.new(
      assistant,
      '30',
      0,
      conversations_scope: authorized_scope
    ).metrics
    result = described_class.new(
      assistant,
      { metric: 'conversations_handled', range: '30', timezone_offset: 0 },
      conversations_scope: authorized_scope
    ).build

    expect(result.dig(:meta, :conversation_count)).to eq(metrics.dig(:conversations_handled, :current))
    expect(result[:payload].pluck(:conversation).pluck(:id)).to eq([authorized_conversation.id])
  end

  it 'redacts contact identity and message content from analytics payloads' do
    payload = described_class.new(
      assistant,
      { metric: 'conversations_handled', range: '30' },
      conversations_scope: authorized_scope
    ).build.fetch(:payload).first

    expect(payload[:message]).to be_nil
    expect(payload[:conversation]).not_to include(:contact_id, :contact_name, :last_message)
    expect(payload.to_json).not_to include('must not leave the analytics endpoint')
  end

  it 'uses the same resolved cohort as the auto-resolution card' do
    create(:reporting_event, account: account, conversation: authorized_conversation,
                             name: 'conversation_bot_resolved', created_at: 2.days.ago)
    create(:reporting_event, account: account, conversation: hidden_conversation,
                             name: 'conversation_bot_resolved', created_at: 2.days.ago)

    metrics = Captain::AssistantStatsBuilder.new(
      assistant,
      '30',
      0,
      conversations_scope: authorized_scope
    ).metrics
    result = described_class.new(
      assistant,
      { metric: 'auto_resolution_rate', range: '30' },
      conversations_scope: authorized_scope
    ).build

    expect(metrics.dig(:auto_resolution_rate, :current)).to eq(100.0)
    expect(result.dig(:meta, :conversation_count)).to eq(1)
    expect(result[:payload].pluck(:conversation).pluck(:id)).to eq([authorized_conversation.id])
  end

  it 'caps pagination inputs' do
    result = described_class.new(
      assistant,
      { metric: 'conversations_handled', range: '30', page: 50_000, per_page: 50_000 },
      conversations_scope: authorized_scope
    ).build

    expect(result[:meta]).to include(current_page: 1_000, per_page: 100)
  end

  it 'loads the drilldown implementation from the LLA-owned tree' do
    expect(described_class.instance_method(:build).source_location.first).to include('/lla/rails/')
  end
end
