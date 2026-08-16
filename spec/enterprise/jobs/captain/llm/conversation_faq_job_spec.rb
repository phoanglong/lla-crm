# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Llm::ConversationFaqJob, type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account, config: { feature_faq: true }) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, first_reply_created_at: Time.zone.now) }
  let(:faq_service) { instance_double(Captain::Llm::ConversationFaqService, generate_suggestions: []) }

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    conversation.update!(status: :resolved)
    allow(Captain::Llm::ConversationFaqService).to receive(:new).and_return(faq_service)
  end

  it 'runs for the assistant currently attached to the resolved conversation' do
    expect(Captain::Llm::ConversationFaqService).to receive(:new)
      .with(assistant, conversation)
      .and_return(faq_service)

    described_class.perform_now(conversation, assistant)

    expect(faq_service).to have_received(:generate_suggestions)
  end

  it 'rejects an assistant replaced after the job was enqueued' do
    replacement = create(:captain_assistant, account: account, config: { feature_faq: true })
    inbox.captain_inbox.update!(captain_assistant: replacement)

    described_class.perform_now(conversation, assistant)

    expect(Captain::Llm::ConversationFaqService).not_to have_received(:new)
  end

  it 'uses a claim scoped to account, assistant, conversation and revision' do
    allow(Redis::Alfred).to receive(:set).and_call_original

    described_class.perform_now(conversation, assistant)

    expect(Redis::Alfred).to have_received(:set) do |key, _token, options|
      expect(key).to include("::#{account.id}::#{assistant.id}::#{conversation.id}::")
      expect(options).to eq(nx: true, ex: described_class::CLAIM_TTL)
    end
  end

  it 'does not run when another worker owns the same revision claim' do
    allow(Redis::Alfred).to receive(:set).and_return(false)

    described_class.perform_now(conversation, assistant)

    expect(Captain::Llm::ConversationFaqService).not_to have_received(:new)
  end

  it 'releases only its own token when processing fails' do
    allow(faq_service).to receive(:generate_suggestions).and_raise(ActiveRecord::Deadlocked)
    allow(Redis::Alfred).to receive(:delete_if_equals)

    expect { described_class.new.perform(conversation, assistant) }.to raise_error(ActiveRecord::Deadlocked)
    expect(Redis::Alfred).to have_received(:delete_if_equals).with(
      a_string_including("::#{conversation.id}::"), kind_of(String)
    )
  end

  it 'rejects a cross-account assistant without claiming or calling the provider' do
    other_assistant = create(:captain_assistant, account: create(:account), config: { feature_faq: true })
    allow(Redis::Alfred).to receive(:set)

    described_class.perform_now(conversation, other_assistant)

    expect(Redis::Alfred).not_to have_received(:set)
    expect(Captain::Llm::ConversationFaqService).not_to have_received(:new)
  end
end
