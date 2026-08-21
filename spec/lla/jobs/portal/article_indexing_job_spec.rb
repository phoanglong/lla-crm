require 'rails_helper'

RSpec.describe Portal::ArticleIndexingJob do
  let(:account) { create(:account, limits: { captain_responses: 40 }) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:article) do
    create(:article, account: account, portal: portal, author: user,
                     title: 'Reset password', description: 'A short guide', content: 'Open settings. Save a new password.')
  end
  let(:vector) { Array.new(1536, 0.1) }

  around do |example|
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'openai' => { 'enabled' => true, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
      }
    ))
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_EMBEDDING_SEARCH_ENABLED' => 'true'
    ) { example.run }
  end

  def build_operation
    article
    account.enable_features!('help_center_embedding_search')
    Lla::Knowledge::IndexOperationService.new(article: article).perform
  end

  def stub_embedding(value: vector)
    service = instance_double(Captain::Llm::EmbeddingService, get_embedding: value)
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)
  end

  it 'creates a versioned shadow index and atomically activates it' do
    operation = build_operation
    stub_embedding

    described_class.perform_now(operation.outboxes.sole.id)

    rows = article.article_embeddings.reload
    expect(rows.count).to eq(article.generate_article_search_terms.size)
    expect(rows).to all(have_attributes(
                          account_id: account.id,
                          portal_id: portal.id,
                          model: 'text-embedding-3-small',
                          dimensions: 1536,
                          index_version: article.lla_search_version,
                          active: true
                        ))
    expect(article.reload).to have_attributes(
      lla_search_active_version: article.lla_search_version,
      lla_search_embedding_model: 'text-embedding-3-small',
      lla_search_embedding_dimensions: 1536
    )
    expect(operation.reload).to have_attributes(state: 'completed', finished_items: 1)
    expect(account.lla_captain_quota_ledgers.sole.consumed_units).to eq(rows.count)
  end

  it 'preserves the last-good active index when a new provider result is invalid' do
    first = build_operation
    stub_embedding
    described_class.perform_now(first.outboxes.sole.id)
    first_ids = article.article_embeddings.active.pluck(:id)
    first_version = article.reload.lla_search_active_version

    with_modified_env('LLA_KNOWLEDGE_EMBEDDING_SEARCH_ENABLED' => 'false') do
      article.update!(content: 'Changed content for a later index')
    end
    second = Lla::Knowledge::IndexOperationService.new(article: article).perform
    service = instance_double(Captain::Llm::EmbeddingService)
    allow(service).to receive(:get_embedding).and_raise(Captain::Llm::EmbeddingService::InvalidEmbedding)
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(service)

    described_class.perform_now(second.outboxes.sole.id)

    expect(article.article_embeddings.active.pluck(:id)).to eq(first_ids)
    expect(article.reload.lla_search_active_version).to eq(first_version)
    expect(second.items.sole.reload).to have_attributes(state: 'failed', last_error_code: 'embedding_invalid_embedding')
  end

  it 'does not call the provider when article content changed after scheduling' do
    operation = build_operation
    with_modified_env('LLA_KNOWLEDGE_EMBEDDING_SEARCH_ENABLED' => 'false') do
      article.update!(content: 'Changed after scheduling')
    end

    expect(Captain::Llm::EmbeddingService).not_to receive(:new)
    described_class.perform_now(operation.outboxes.sole.id)

    expect(operation.items.sole.reload).to have_attributes(state: 'failed', last_error_code: 'embedding_stale_article')
    expect(article.article_embeddings).to be_empty
  end
end
