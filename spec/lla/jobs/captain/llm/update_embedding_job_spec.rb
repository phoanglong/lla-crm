# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Llm::UpdateEmbeddingJob, type: :job do
  let(:article) { create(:article) }
  # The row starts with a placeholder vector rather than no vector at all. Wave G3's
  # migration installed `chk_lla_article_embeddings_profile`, which requires
  # `embedding IS NOT NULL` and a matching dimension on every row, so a record with a
  # null embedding is not a state this table can ever hold. Rejection is therefore
  # asserted as "the stored vector is unchanged", not "the vector is still nil".
  # A different *direction*, not just a different magnitude: `has_neighbors
  # normalize: true` scales every vector to unit length, so a uniform placeholder
  # and a uniform result are stored identically and could not be told apart.
  let(:placeholder) { [1.0] + Array.new(1535, 0.0) }
  let(:embedding) { Array.new(1536, 0.25) }
  let(:record) do
    ArticleEmbedding.create!(article: article, term: 'stable source text', embedding: placeholder)
  end
  let(:embedding_service) { instance_double(Captain::Llm::EmbeddingService, get_embedding: embedding) }

  before do
    # A deliberately legacy-shaped record class: the pre-wave version derived its
    # tenant from the article instead of carrying it, and the job still has to accept
    # that shape through the GlobalID callback. The stub fills the tenant and profile
    # columns the current schema requires so the fixture is insertable; what is under
    # test is the job, not the columns.
    stub_const('ArticleEmbedding', Class.new(ApplicationRecord) do
      self.table_name = 'article_embeddings'

      belongs_to :article
      delegate :account_id, to: :article
      has_neighbors :embedding, normalize: true

      before_validation do
        self[:account_id] ||= article&.account_id
        self[:portal_id] ||= article&.portal_id
        self[:model] ||= 'text-embedding-3-small'
        self[:dimensions] ||= 1536
        self[:index_version] ||= 1
        self[:term_digest] ||= Digest::SHA256.hexdigest(term.to_s)
        self[:content_digest] ||= Digest::SHA256.hexdigest(term.to_s)
      end
    end)
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedding_service)
  end

  def stored_vector
    record.reload.embedding.to_a.map { |value| value.round(4) }
  end

  it 'updates an allowlisted record through the typed tenant-bound contract' do
    digest = Digest::SHA256.hexdigest(record.term)

    described_class.perform_now('ArticleEmbedding', record.id, account_id: article.account_id, content_digest: digest)

    expect(record.reload.embedding.to_a.length).to eq(1536)
    expect(stored_vector).not_to eq(placeholder.map { |value| value.round(4) })
  end

  it 'rejects a record from another account before calling the provider' do
    digest = Digest::SHA256.hexdigest(record.term)
    before_vector = stored_vector

    described_class.perform_now('ArticleEmbedding', record.id, account_id: create(:account).id, content_digest: digest)

    expect(embedding_service).not_to have_received(:get_embedding)
    expect(stored_vector).to eq(before_vector)
  end

  it 'rejects non-allowlisted record types without constantizing them' do
    described_class.perform_now('Account', article.account_id, account_id: article.account_id, content_digest: '0' * 64)

    expect(embedding_service).not_to have_received(:get_embedding)
  end

  it 'does not overwrite a newer term when content changes during embedding' do
    digest = Digest::SHA256.hexdigest(record.term)
    before_vector = stored_vector
    allow(embedding_service).to receive(:get_embedding) do
      record.update_column(:term, 'newer source text') # rubocop:disable Rails/SkipsModelValidations
      embedding
    end

    described_class.perform_now('ArticleEmbedding', record.id, account_id: article.account_id, content_digest: digest)

    expect(stored_vector).to eq(before_vector)
  end

  it 'keeps the legacy GlobalID callback stale-safe for the Help Center transition' do
    before_vector = stored_vector

    described_class.perform_now(record, record.term)

    expect(record.reload.embedding.to_a.length).to eq(1536)
    expect(stored_vector).not_to eq(before_vector)
  end
end
