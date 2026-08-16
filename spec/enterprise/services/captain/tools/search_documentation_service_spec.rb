require 'rails_helper'

RSpec.describe Captain::Tools::SearchDocumentationService do
  let(:assistant) { create(:captain_assistant) }
  let(:service) { described_class.new(assistant) }
  let(:question) { 'How to create a new account?' }
  let(:answer) { 'You can create a new account by clicking on the Sign Up button.' }
  let(:external_link) { 'https://example.com/docs/create-account' }

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('search_documentation')
    end
  end

  describe '#description' do
    it 'returns the service description' do
      expect(service.description).to eq('Search and retrieve documentation from knowledge base')
    end
  end

  describe '#parameters' do
    it 'defines query parameter' do
      expect(service.parameters.keys).to contain_exactly(:query)
    end
  end

  describe '#execute' do
    let(:translation_service) { instance_double(Captain::Llm::TranslateQueryService) }
    let!(:response) do
      create(
        :captain_assistant_response,
        assistant: assistant,
        question: question,
        answer: answer,
        status: 'approved'
      )
    end

    let(:documentable) { create(:captain_document, external_link: external_link) }

    before do
      allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: assistant.account).and_return(translation_service)
      allow(translation_service).to receive(:translate)
        .with(question, target_language: assistant.account.locale_english_name)
        .and_return(question)
    end

    context 'when matching responses exist' do
      before do
        response.update(documentable: documentable)
        allow(Captain::AssistantResponse).to receive(:search)
          .with(question, account_id: assistant.account_id, assistant_id: assistant.id)
          .and_return([response])
      end

      it 'returns formatted responses for the search query' do
        result = service.execute(query: question)

        expect(result).to include(question)
        expect(result).to include(answer)
        expect(result).to include(external_link)
      end
    end

    context 'when no matching responses exist' do
      before do
        allow(Captain::AssistantResponse).to receive(:search)
          .with(question, account_id: assistant.account_id, assistant_id: assistant.id)
          .and_return([])
      end

      it 'returns an empty string' do
        expect(service.execute(query: question)).to eq('No FAQs found for the given query')
      end
    end
  end
end
