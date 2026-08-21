require 'rails_helper'

RSpec.describe Lla::Knowledge::SafePageFetcher do
  let(:account) { create(:account) }
  let(:crawler) do
    instance_double(
      Captain::Tools::SimplePageCrawlService,
      success?: true,
      page_title: 'Docs',
      meta_description: 'Product docs',
      favicon_url: 'https://docs.example.com/favicon.ico',
      body_markdown: '# Safe documentation',
      page_links: ['https://docs.example.com/guide', 'https://evil.example/escape']
    )
  end

  it 'performs zero fetches when provider consent or switches are absent' do
    expect(Captain::Tools::SimplePageCrawlService).not_to receive(:new)

    expect { described_class.new(account: account, url: 'https://docs.example.com').perform }
      .to raise_error(Lla::Knowledge::ProviderPolicy::Denied)
  end

  it 'returns bounded same-origin metadata after authorization' do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'direct_fetch' => { 'enabled' => true, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
      }
    ))
    allow(Captain::Tools::SimplePageCrawlService).to receive(:new).and_return(crawler)

    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_WEBSITE_ANALYSIS_ENABLED' => 'true'
    ) do
      result = described_class.new(account: account, url: 'https://docs.example.com').perform

      expect(result.url).to eq('https://docs.example.com/')
      expect(result.links).to eq(['https://docs.example.com/guide'])
      expect(result.favicon_url).to eq('https://docs.example.com/favicon.ico')
    end
  end
end
