require 'rails_helper'

RSpec.describe Lla::Knowledge::SourceAdapter do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('adapter-operation'),
      request_digest: Digest::SHA256.hexdigest('adapter-request')
    )
  end
  let(:fetch_result) do
    Lla::Knowledge::SafePageFetcher::Result.new(
      url: 'https://docs.example.com/',
      title: 'Docs',
      description: 'Help',
      favicon_url: nil,
      markdown: '# Safe docs',
      links: ['https://docs.example.com/start?utm=1', 'https://attacker.example/prompt']
    )
  end

  before do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'direct_fetch' => { 'enabled' => true, 'version' => 'v1', 'accepted_at' => Time.current.iso8601 }
      }
    ))
    allow(InstallationConfig).to receive(:find_by).and_call_original
    allow(InstallationConfig).to receive(:find_by).with(name: described_class::FIRECRAWL_KEY).and_return(nil)
  end

  around do |example|
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_EXTERNAL_CRAWL_ENABLED' => 'true',
      'LLA_KNOWLEDGE_ARTICLE_GENERATION_ENABLED' => 'true'
    ) { example.run }
  end

  it 'uses the safe direct adapter, strips tracking queries and rejects cross-origin discoveries' do
    fetcher = instance_double(Lla::Knowledge::SafePageFetcher, perform: fetch_result)
    allow(Lla::Knowledge::SafePageFetcher).to receive(:new).and_return(fetcher)

    links = described_class.new(account: account, operation: operation, capability: :external_crawl)
                           .discover(portal.homepage_link, limit: 10)

    expect(links.map(&:url)).to contain_exactly('https://docs.example.com/', 'https://docs.example.com/start')
    expect(operation.reload.provider_consent_digests.fetch('direct_fetch')).to match(/\A[0-9a-f]{64}\z/)
  end

  it 'rejects a cross-origin page list before any network fetch' do
    expect(Lla::Knowledge::SafePageFetcher).not_to receive(:new)

    expect do
      described_class.new(account: account, operation: operation, capability: :article_generation)
                     .fetch_pages(['https://attacker.example/invented'])
    end.to raise_error(described_class::Unavailable, 'lla_knowledge_source_origin_rejected')
  end

  it 'bounds source content returned to the writer' do
    oversized = fetch_result.with(markdown: 'a' * (described_class::MAX_PAGE_MARKDOWN + 50))
    allow(Lla::Knowledge::SafePageFetcher).to receive(:new).and_return(
      instance_double(Lla::Knowledge::SafePageFetcher, perform: oversized)
    )

    page = described_class.new(account: account, operation: operation, capability: :article_generation)
                          .fetch_pages(['https://docs.example.com/']).sole

    expect(page.markdown.length).to eq(described_class::MAX_PAGE_MARKDOWN)
  end

  it 'fails closed without tenant consent and performs no fetch' do
    account.update!(custom_attributes: account.custom_attributes.except('lla_provider_consents'))
    expect(Lla::Knowledge::SafePageFetcher).not_to receive(:new)

    expect do
      described_class.new(account: account, operation: operation, capability: :external_crawl)
                     .discover(portal.homepage_link, limit: 10)
    end.to raise_error(Lla::Knowledge::ProviderPolicy::Denied)
  end
end
