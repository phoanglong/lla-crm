require 'rails_helper'

RSpec.describe Captain::Conversation::MessageHistoryBuilderService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }

  it 'keeps only the newest bounded public context in chronological order' do
    62.times do |index|
      create(:message, conversation: conversation, account: account, message_type: :incoming, content: "message-#{index}")
    end
    create(:message, conversation: conversation, account: account, message_type: :incoming, private: true, content: 'private')

    history = described_class.new(conversation: conversation).perform

    expect(history.length).to eq(described_class::MAX_MESSAGES)
    expect(history.first[:content]).to eq('message-2')
    expect(history.last[:content]).to eq('message-61')
    expect(history.to_json).not_to include('private')
  end

  it 'includes only the supported resolution activity boundary' do
    create(:message, conversation: conversation, account: account, message_type: :activity,
                     content_attributes: { activity: { type: 'conversation_status_changed', status: 'resolved' } })
    create(:message, conversation: conversation, account: account, message_type: :activity,
                     content_attributes: { activity: { type: 'assignee_changed' } })

    expect(described_class.new(conversation: conversation).perform).to eq(
      [{ content: described_class::RESOLUTION_MARKER, role: 'assistant' }]
    )
  end

  it 'bounds oversized message content' do
    create(:message, conversation: conversation, account: account, message_type: :incoming, content: 'x' * 20_000)

    content = described_class.new(conversation: conversation).perform.first[:content]

    expect(content.bytesize).to eq(described_class::MAX_CONTENT_BYTES)
  end

  it 'keeps the newest messages within the total byte budget' do
    12.times do |index|
      create(:message, conversation: conversation, account: account, message_type: :incoming,
                       content: "message-#{index}:#{'x' * 20_000}")
    end

    history = described_class.new(conversation: conversation).perform

    expect(history.sum { |message| message[:content].bytesize }).to be <= described_class::MAX_TOTAL_BYTES
    expect(history.last[:content]).to start_with('message-11:')
    expect(history.to_json).not_to include('message-0:')
  end
end
