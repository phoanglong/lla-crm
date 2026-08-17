require 'rails_helper'

RSpec.describe PageCrawlerService do
  let(:account) { create(:account) }
  let(:result) do
    Lla::Knowledge::SafePageFetcher::Result.new(
      url: 'https://docs.example.com/', title: 'Docs', description: 'Help', favicon_url: nil,
      markdown: '# Body', links: ['https://docs.example.com/start']
    )
  end

  it 'delegates legacy read methods to the tenant-gated safe fetcher' do
    expect(Lla::Knowledge::SafePageFetcher).to receive(:new)
      .with(account: account, url: 'https://docs.example.com/', capability: :external_crawl)
      .and_return(instance_double(Lla::Knowledge::SafePageFetcher, perform: result))

    crawler = described_class.new('https://docs.example.com/', account: account)

    expect(crawler.page_links).to eq(Set['https://docs.example.com/start'])
    expect(crawler.page_title).to eq('Docs')
    expect(crawler.body_text_content).to eq('# Body')
  end

  it 'requires explicit tenant context' do
    expect { described_class.new('https://docs.example.com/') }.to raise_error(ArgumentError, /account/)
  end
end
