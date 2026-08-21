require 'rails_helper'

RSpec.describe Lla::Knowledge::ArticleSemanticSearch do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:other_portal) { create(:portal, account: account) }
  let(:near_article) { create(:article, account: account, portal: portal, title: 'Reset password', status: :published) }
  let(:draft_article) { create(:article, account: account, portal: portal, title: 'Draft password', status: :draft) }
  let(:other_article) { create(:article, account: account, portal: other_portal, title: 'Other portal', status: :published) }
  let(:query_vector) { [1.0] + Array.new(1535, 0.0) }
  let(:far_vector) { [0.0, 1.0] + Array.new(1534, 0.0) }

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

  def create_embedding(article, vector)
    ArticleEmbedding.create!(
      article: article,
      account_id: article.account_id,
      portal_id: article.portal_id,
      model: 'text-embedding-3-small',
      dimensions: 1536,
      content_digest: article.lla_search_content_digest,
      term_digest: Digest::SHA256.hexdigest("term-#{article.id}"),
      index_version: article.lla_search_version,
      term: article.title,
      embedding: vector,
      active: true
    )
  end

  def search(filters = {})
    described_class.new(
      scope: Article.all,
      portal: portal,
      query: 'password help',
      filters: filters,
      requester_key: '203.0.113.20'
    ).perform
  end

  it 'returns only threshold-matching published articles from the requested tenant and portal' do
    [near_article, draft_article, other_article]
    account.enable_features!('help_center_embedding_search')
    create_embedding(near_article, query_vector)
    create_embedding(draft_article, query_vector)
    create_embedding(other_article, query_vector)
    far_article = create(:article, account: account, portal: portal, title: 'Far result', status: :published)
    create_embedding(far_article, far_vector)
    allow(Lla::Knowledge::PublicSearchRateLimiter).to receive(:allowed?).and_return(true)
    service = instance_double(Captain::Llm::EmbeddingService, get_embedding: query_vector)
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)

    expect(search.pluck(:id)).to eq([near_article.id])
  end

  it 'fails closed before provider work when entitlement is missing' do
    near_article
    allow(Lla::Knowledge::PublicSearchRateLimiter).to receive(:allowed?).and_return(true)

    expect(Captain::Llm::EmbeddingService).not_to receive(:new)
    expect { search }.to raise_error(described_class::Unavailable, 'Lla::Knowledge::ProviderPolicy::Denied')
  end

  it 'fails closed before provider work when the per-portal request budget is exhausted' do
    near_article
    account.enable_features!('help_center_embedding_search')
    allow(Lla::Knowledge::PublicSearchRateLimiter).to receive(:allowed?).and_return(false)

    expect(Captain::Llm::EmbeddingService).not_to receive(:new)
    expect { search }.to raise_error(described_class::Unavailable, 'rate_limited')
  end
end
