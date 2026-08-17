require 'rails_helper'

RSpec.describe Onboarding::HelpCenterArticleBuilder do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('builder-operation'),
      request_digest: Digest::SHA256.hexdigest('builder-request')
    )
  end
  let(:article_plan) { { title: 'Start', urls: ['https://docs.example.com/start'] } }
  let(:item) do
    Lla::Knowledge::GenerationStateService.new(operation).plan!(
      allowed_urls: article_plan[:urls],
      categories: [{ name: 'Start' }],
      articles: [{ title: 'Start', category_name: 'Start', urls: article_plan[:urls] }]
    )
    operation.items.sole
  end
  let(:page) do
    Lla::Knowledge::SourceAdapter::Page.new(
      url: 'https://docs.example.com/start', markdown: '# Source', page_title: 'Start'
    )
  end

  before do
    allow(Lla::Knowledge::SourceAdapter).to receive(:new).and_return(
      instance_double(Lla::Knowledge::SourceAdapter, fetch_pages: [page])
    )
    writer = instance_double(
      Captain::Llm::ArticleWriterService,
      perform: { message: { title: '<b>Safe</b>', description: 'Summary', content: '# Body<script>x</script>' } }
    )
    allow(writer).to receive(:with_quota_idempotency_key).and_return(writer)
    allow(Captain::Llm::ArticleWriterService).to receive(:new).and_return(writer)
  end

  it 'returns a sanitized draft payload with exact source provenance' do
    result = described_class.new(
      account: account, portal: portal, user: user,
      operation: operation, item: item, article: article_plan
    ).perform

    expect(result).to include(title: 'Safe', description: 'Summary', meta: { source_urls: ['https://docs.example.com/start'] })
    expect(result[:content]).to eq('# Body')
  end

  it 'fails before source or provider use for forged tenant context' do
    forged_account = create(:account)
    expect(Lla::Knowledge::SourceAdapter).not_to receive(:new)

    expect do
      described_class.new(
        account: forged_account, portal: portal, user: user,
        operation: operation, item: item, article: article_plan
      ).perform
    end.to raise_error(Onboarding::HelpCenterErrors::ArticleBuildFailed, 'lla_knowledge_tenant_mismatch')
  end

  it 'fails with a stable code when no source page survives validation' do
    allow(Lla::Knowledge::SourceAdapter).to receive(:new).and_return(
      instance_double(Lla::Knowledge::SourceAdapter, fetch_pages: [])
    )

    expect do
      described_class.new(
        account: account, portal: portal, user: user,
        operation: operation, item: item, article: article_plan
      ).perform
    end.to raise_error(Onboarding::HelpCenterErrors::ArticleBuildFailed, 'lla_knowledge_sources_unusable')
  end
end
