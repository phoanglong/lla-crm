# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Llm::UpdateEmbeddingJob, type: :job do
  let(:article) { create(:article) }
  let(:record) { ArticleEmbedding.create!(article: article, term: 'stable source text') }
  let(:embedding) { Array.new(1536, 0.25) }
  let(:embedding_service) { instance_double(Captain::Llm::EmbeddingService, get_embedding: embedding) }

  before do
    stub_const('ArticleEmbedding', Class.new(ApplicationRecord) do
      self.table_name = 'article_embeddings'

      belongs_to :article
      delegate :account_id, to: :article
      has_neighbors :embedding, normalize: true
    end)
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedding_service)
  end

  it 'updates an allowlisted record through the typed tenant-bound contract' do
    digest = Digest::SHA256.hexdigest(record.term)

    described_class.perform_now('ArticleEmbedding', record.id, account_id: article.account_id, content_digest: digest)

    expect(record.reload.embedding.to_a.length).to eq(1536)
  end

  it 'rejects a record from another account before calling the provider' do
    digest = Digest::SHA256.hexdigest(record.term)

    described_class.perform_now('ArticleEmbedding', record.id, account_id: create(:account).id, content_digest: digest)

    expect(embedding_service).not_to have_received(:get_embedding)
    expect(record.reload.embedding).to be_nil
  end

  it 'rejects non-allowlisted record types without constantizing them' do
    described_class.perform_now('Account', article.account_id, account_id: article.account_id, content_digest: '0' * 64)

    expect(embedding_service).not_to have_received(:get_embedding)
  end

  it 'does not overwrite a newer term when content changes during embedding' do
    digest = Digest::SHA256.hexdigest(record.term)
    allow(embedding_service).to receive(:get_embedding) do
      record.update_column(:term, 'newer source text') # rubocop:disable Rails/SkipsModelValidations
      embedding
    end

    described_class.perform_now('ArticleEmbedding', record.id, account_id: article.account_id, content_digest: digest)

    expect(record.reload.embedding).to be_nil
  end

  it 'keeps the legacy GlobalID callback stale-safe for the Help Center transition' do
    described_class.perform_now(record, record.term)

    expect(record.reload.embedding.to_a.length).to eq(1536)
  end
end
