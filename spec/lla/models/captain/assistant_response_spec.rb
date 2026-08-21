require 'rails_helper'

RSpec.describe Captain::AssistantResponse, type: :model do
  describe 'tenant boundaries' do
    it 'requires explicit tenant and assistant scopes for semantic search' do
      expect { described_class.search('reset password') }.to raise_error(ArgumentError)
    end

    it 'rejects a document owned by another account' do
      assistant = create(:captain_assistant)
      other_document = create(:captain_document)

      response = build(:captain_assistant_response, assistant: assistant, documentable: other_document)

      expect(response).not_to be_valid
      expect(response.errors[:documentable]).to include('must belong to the same account as the assistant')
    end
  end

  describe 'embedding lifecycle' do
    it 'queues an embedding for a new FAQ without one' do
      expect(Captain::Llm::ResponseEmbeddingJob).to receive(:perform_later).with(instance_of(described_class))

      create(:captain_assistant_response, embedding: nil)
    end

    it 'clears a stale embedding and queues regeneration when content changes' do
      response = create(:captain_assistant_response)
      allow(Captain::Llm::ResponseEmbeddingJob).to receive(:perform_later)

      response.update!(question: 'Updated question?')

      expect(response.reload.embedding).to be_nil
      expect(Captain::Llm::ResponseEmbeddingJob).to have_received(:perform_later).with(response)
    end
  end
end
