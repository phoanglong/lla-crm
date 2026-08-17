require 'rails_helper'

RSpec.describe 'LLA public article semantic search', type: :request do
  let(:account) { create(:account) }
  let(:portal) do
    create(:portal, account: account, slug: 'lla-search', custom_domain: 'www.example.com',
                    config: { allowed_locales: ['en'] })
  end
  let(:category) { create(:category, account: account, portal: portal, locale: 'en', slug: 'guides') }
  let!(:article) do
    create(:article, account: account, portal: portal, category: category,
                     locale: 'en', status: :published, title: 'Password guide', content: 'funny reset instructions')
  end
  let(:url) { "/hc/#{portal.slug}/en/articles.json" }

  around do |example|
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_EMBEDDING_SEARCH_ENABLED' => 'true'
    ) { example.run }
  end

  it 'uses bounded vector search only when the account feature and capability are enabled' do
    account.enable_features!('help_center_embedding_search')
    allow(Article).to receive(:vector_search).and_return(Article.where(id: article.id))

    get url, params: { query: 'password', per_page: 3 }

    expect(response).to have_http_status(:success)
    expected = { account_id: account.id, portal_id: portal.id, query: 'password', locale: 'en', limit: '3' }
    expect(Article).to have_received(:vector_search).with(hash_including(expected))
  end

  it 'does not invoke vector search for blank input or a disabled account feature' do
    allow(Article).to receive(:vector_search)

    get url, params: { query: 'password' }
    expect(Article).not_to have_received(:vector_search)

    account.enable_features!('help_center_embedding_search')
    get url, params: { query: '   ' }
    expect(Article).not_to have_received(:vector_search)
  end

  it 'falls back to local lexical search when semantic search is unavailable' do
    account.enable_features!('help_center_embedding_search')
    allow(Article).to receive(:vector_search).and_raise(Lla::Knowledge::ArticleSemanticSearch::Unavailable, 'provider')

    get url, params: { query: 'funny' }

    expect(response).to have_http_status(:success)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([article.id])
  end
end
