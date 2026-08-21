require 'rails_helper'

RSpec.describe ArticleEmbedding do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:article) { create(:article, account: account, portal: portal) }
  let(:attributes) do
    {
      article: article,
      account_id: account.id,
      portal_id: portal.id,
      model: 'text-embedding-3-small',
      dimensions: 1536,
      content_digest: article.lla_search_content_digest,
      term_digest: Digest::SHA256.hexdigest('reset password'),
      index_version: article.lla_search_version,
      term: 'reset password',
      embedding: Array.new(1536, 0.1)
    }
  end

  it 'accepts a registered vector bound to the article tenant and portal' do
    expect(described_class.new(attributes)).to be_valid
  end

  it 'rejects forged tenant coordinates' do
    other_account = create(:account)
    embedding = described_class.new(attributes.merge(account_id: other_account.id))

    expect(embedding).not_to be_valid
    expect(embedding.errors[:article]).to include('must belong to the embedding tenant and portal')
  end

  it 'rejects a vector whose dimensions do not match its profile' do
    embedding = described_class.new(attributes.merge(embedding: [0.1, 0.2]))

    expect(embedding).not_to be_valid
    expect(embedding.errors[:embedding]).to include('dimension does not match the registered profile')
  end
end
