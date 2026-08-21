# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Llm::ConversationFaqService, type: :service do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account, config: { feature_faq: true }) }
  let(:contact) { create(:contact, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, first_reply_created_at: Time.zone.now)
  end
  let(:embedding) { [1.0] + Array.new(1535, 0.0) }
  let(:embedding_service) { instance_double(Captain::Llm::EmbeddingService, get_embedding: embedding) }
  let(:candidate) { { 'question' => 'How is the feature enabled?', 'answer' => 'Enable it in Settings.' } }
  let(:service) { described_class.new(assistant, conversation) }

  before do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact,
                     message_type: :incoming, content: 'How do I enable the feature?')
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: agent,
                     message_type: :outgoing, content: 'Enable it in Settings.')
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    conversation.update!(status: :resolved)
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedding_service)
  end

  it 'creates one open suggestion and attached source observation' do
    stub_json(service, generation: { 'faqs' => [candidate] })

    result = service.generate_suggestions

    suggestion = assistant.faq_suggestions.find_by!(question: candidate['question'])
    expect(result).to contain_exactly(instance_of(Captain::FaqObservation))
    expect(suggestion).to be_open
    expect(suggestion.source_count).to eq(1)
    expect(suggestion.observations.attached.find_by(conversation: conversation)).to be_present
  end

  it 'keeps effective persistence idempotent across sequential retries' do
    first = described_class.new(assistant, conversation)
    second = described_class.new(assistant, conversation)
    stub_json(first, generation: { 'faqs' => [candidate] }, matching: { 'same_faq' => true })
    stub_json(second, generation: { 'faqs' => [candidate] }, matching: { 'same_faq' => true })

    first.generate_suggestions
    second.generate_suggestions

    expect(assistant.faq_suggestions.count).to eq(1)
    expect(Captain::FaqObservation.where(conversation: conversation).count).to eq(1)
    expect(assistant.faq_suggestions.first.source_count).to eq(1)
  end

  it 'rejects malformed, oversized and sensitive candidates before embedding' do
    stub_json(
      service,
      generation: {
        'faqs' => [
          { 'question' => 'Email?', 'answer' => 'Write to private@example.com' },
          { 'question' => 'Q' * 301, 'answer' => 'Answer' },
          { 'question' => 5, 'answer' => 'Answer' }
        ]
      }
    )

    expect(service.generate_suggestions).to eq([])
    expect(embedding_service).not_to have_received(:get_embedding)
  end

  it 'isolates a poison candidate and persists a later valid candidate' do
    other = { 'question' => 'Where is the setting?', 'answer' => 'It is in the account menu.' }
    stub_json(service, generation: { 'faqs' => [candidate, other] })
    attempts = 0
    allow(embedding_service).to receive(:get_embedding) do
      attempts += 1
      raise RubyLLM::Error, 'provider detail' if attempts == 1

      embedding
    end
    allow(ChatwootExceptionTracker).to receive(:new).and_return(
      instance_double(ChatwootExceptionTracker, capture_exception: nil)
    )

    service.generate_suggestions

    expect(assistant.faq_suggestions.pluck(:question)).to eq([other['question']])
  end

  it 'creates a discarded observation when an approved FAQ is semantically identical' do
    create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      status: :approved,
      question: 'How do I enable this?',
      answer: 'Use Settings.',
      embedding: embedding
    )
    stub_json(service, generation: { 'faqs' => [candidate] }, matching: { 'same_faq' => true })

    service.generate_suggestions

    expect(assistant.faq_suggestions).to be_empty
    expect(Captain::FaqObservation.discarded.find_by(conversation: conversation)).to be_present
  end

  it 'does not disable vector indexes for candidate shortlisting' do
    create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      status: :approved,
      question: 'A related FAQ',
      answer: 'A related answer',
      embedding: embedding
    )
    stub_json(service, generation: { 'faqs' => [candidate] }, matching: { 'same_faq' => false })
    allow(ApplicationRecord.connection).to receive(:execute).and_call_original

    service.generate_suggestions

    expect(ApplicationRecord.connection).not_to have_received(:execute).with(/enable_indexscan/i)
  end

  it 'rejects a cross-account assistant before calling the model or embedding provider' do
    invalid = described_class.new(create(:captain_assistant, account: create(:account)), conversation)
    allow(invalid).to receive(:request_json)

    expect(invalid.generate_suggestions).to eq([])
    expect(invalid).not_to have_received(:request_json)
    expect(embedding_service).not_to have_received(:get_embedding)
  end

  describe Captain::Llm::ConversationFaqContentService do
    it 'includes only bounded public customer and human-agent content' do
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: agent,
                       message_type: :outgoing, private: true, content: 'private-secret')
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: assistant,
                       message_type: :outgoing, content: 'captain-noise')

      content = described_class.new(assistant, conversation).generate

      expect(content).to include('How do I enable the feature?', 'Enable it in Settings.')
      expect(content).not_to include('private-secret', 'captain-noise')
      expect(content.bytesize).to be <= described_class::MAX_CONTENT_BYTES
    end
  end

  def stub_json(target, generation:, matching: { 'same_faq' => false })
    allow(target).to receive(:request_json) do |feature:, **|
      feature == described_class::GENERATION_FEATURE ? generation : matching
    end
  end
end
