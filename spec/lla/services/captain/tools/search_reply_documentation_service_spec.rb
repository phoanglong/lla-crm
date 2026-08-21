# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Tools::SearchReplyDocumentationService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(account: account, assistant: assistant) }

  it 'rejects a broad query before translation or vector search' do
    expect(Captain::Llm::TranslateQueryService).not_to receive(:new)
    expect(service.execute(query: '%')).to eq('Please provide a more specific documentation query')
  end

  it 'does not search with an assistant from another account' do
    foreign_assistant = create(:captain_assistant)
    foreign_service = described_class.new(account: account, assistant: foreign_assistant)
    expect(Captain::Llm::EmbeddingService).not_to receive(:new)

    expect(foreign_service.send(:search_responses, 'order status')).to be_empty
  end

  it 'bounds formatted FAQ output' do
    response = instance_double(
      Captain::AssistantResponse,
      question: 'Question',
      answer: 'x' * 40_000,
      documentable: nil
    )
    translation = instance_double(Captain::Llm::TranslateQueryService, translate: 'order status')
    allow(Captain::Llm::TranslateQueryService).to receive(:new).and_return(translation)
    allow(service).to receive(:search_responses).and_return([response])

    expect(service.execute(query: 'order status').bytesize)
      .to be <= Captain::Tools::PermissionHelpers::MAX_OUTPUT_BYTES
  end
end
