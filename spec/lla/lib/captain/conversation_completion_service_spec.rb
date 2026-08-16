# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ConversationCompletionService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:service) { described_class.new(account: account, conversation_display_id: conversation.display_id) }

  before { account.enable_features!('captain_tasks') }

  it 'fails closed when the conversation belongs to another account' do
    other_account = create(:account)
    other_account.enable_features!('captain_tasks')

    result = described_class.new(account: other_account, conversation_display_id: conversation.display_id).perform

    expect(result).to eq(complete: false, reason: 'Conversation not found')
  end

  it 'rejects a non-boolean completion result' do
    allow(service).to receive(:format_evaluation_input).and_return('bounded transcript')
    allow(service).to receive(:make_api_call).and_return(message: { 'complete' => 'true', 'reason' => 'unsafe' })

    expect(service.perform).to eq(complete: false, reason: 'Invalid completion value')
  end

  it 'bounds recent public transcript bytes without splitting invalid UTF-8' do
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: 'a' * 63_900)
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :outgoing, content: 'b' * 500)
    allow(service).to receive(:make_api_call) do |messages:, **|
      content = messages.last.fetch(:content)
      expect(content.bytesize).to be <= described_class::MAX_TRANSCRIPT_BYTES + 100
      expect(content).to be_valid_encoding
      { message: { 'complete' => false, 'reason' => 'Needs review' } }
    end

    expect(service.perform[:complete]).to be false
  end

  it 'does not send raw transcript messages to the generic content instrumentation path' do
    expect(service).to receive(:instrument_llm_call).with(anything).and_call_original
    expect { service.send(:instrument_llm_call, messages: [{ content: 'private text' }]) { :ok } }.not_to raise_error
  end
end
