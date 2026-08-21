require 'rails_helper'

RSpec.describe Captain::Onboarding::WebsiteAnalyzerService do
  let(:account) { create(:account) }
  let(:page) do
    Lla::Knowledge::SafePageFetcher::Result.new(
      url: 'https://example.com/', title: 'Example', description: 'Support',
      favicon_url: 'https://example.com/favicon.ico', markdown: 'Untrusted website', links: []
    )
  end

  before do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'direct_fetch' => { 'enabled' => true, 'version' => 'v1', 'accepted_at' => Time.current.iso8601 },
        'openai' => { 'enabled' => true, 'version' => 'v1', 'accepted_at' => Time.current.iso8601 }
      }
    ))
  end

  around do |example|
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_WEBSITE_ENRICHMENT_ENABLED' => 'true'
    ) { example.run }
  end

  it 'returns bounded plain business identity from a safe page snapshot' do
    allow(Lla::Knowledge::SafePageFetcher).to receive(:new).and_return(
      instance_double(Lla::Knowledge::SafePageFetcher, perform: page)
    )
    service = described_class.new(account: account, website_url: 'https://example.com/?tracking=1')
    allow(service).to receive(:make_api_call).and_return(
      message: {
        business_name: '<b>Example</b>', suggested_assistant_name: '<i>Helper</i>',
        description: '<script>x</script>Customer support'
      }
    )

    result = service.analyze

    expect(result).to include(success: true)
    expect(result[:data]).to include(
      business_name: 'Example', suggested_assistant_name: 'Helper',
      description: 'Customer support', website_url: 'https://example.com/'
    )
  end

  it 'returns a stable fallback and makes no provider call without consent' do
    account.update!(custom_attributes: {})
    service = described_class.new(account: account, website_url: 'https://example.com/')
    expect(service).not_to receive(:make_api_call)

    expect(service.analyze).to include(
      success: false, error: 'lla_knowledge_provider_disabled',
      data: include(website_url: 'https://example.com/')
    )
  end
end
