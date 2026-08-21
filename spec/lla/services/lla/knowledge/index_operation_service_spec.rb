require 'rails_helper'

RSpec.describe Lla::Knowledge::IndexOperationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:article) { create(:article, account: account, portal: portal, author: user) }

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

  it 'creates one idempotent reindex operation bound to the article version and model profile' do
    article
    account.enable_features!('help_center_embedding_search')

    first = described_class.new(article: article).perform
    replay = described_class.new(article: article).perform

    expect(replay.id).to eq(first.id)
    expect(first.items.sole).to have_attributes(item_type: 'reindex', source_digest: article.lla_search_content_digest)
    expect(first.outboxes.sole.payload).to include(
      article_id: article.id,
      content_digest: article.lla_search_content_digest,
      index_version: article.lla_search_version,
      model: 'text-embedding-3-small',
      dimensions: 1536
    )
  end

  it 'requires both account entitlement and provider consent before persistence' do
    article

    expect { described_class.new(article: article).perform }
      .to raise_error(described_class::InvalidRequest, 'embedding search is unavailable')
      .and not_change(Lla::Knowledge::GenerationOperation, :count)

    account.enable_features!('help_center_embedding_search')
    account.update!(custom_attributes: account.custom_attributes.except('lla_provider_consents'))
    expect { described_class.new(article: article).perform }
      .to raise_error(Lla::Knowledge::ProviderPolicy::Denied)
      .and not_change(Lla::Knowledge::GenerationOperation, :count)
  end

  it 'rejects an article whose portal and account coordinates are forged' do
    account.enable_features!('help_center_embedding_search')
    other_portal = create(:portal)
    allow(article).to receive(:portal).and_return(other_portal)

    expect { described_class.new(article: article).perform }
      .to raise_error(described_class::InvalidRequest, 'article tenant is inconsistent')
      .and not_change(Lla::Knowledge::GenerationOperation, :count)
  end
end
