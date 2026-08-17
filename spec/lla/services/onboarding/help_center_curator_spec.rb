require 'rails_helper'

RSpec.describe Onboarding::HelpCenterCurator do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('curator-operation'),
      request_digest: Digest::SHA256.hexdigest('curator-request')
    )
  end
  let(:links) do
    [
      Lla::Knowledge::SourceAdapter::Link.new(
        url: 'https://docs.example.com/start', title: 'Start', description: 'Setup'
      )
    ]
  end
  let(:message) do
    {
      categories: [{ name: 'Start', description: 'Setup' }, { name: 'Unused' }],
      articles: [
        { title: 'Valid', category_name: 'Start', urls: ['https://docs.example.com/start'] },
        { title: 'Invented', category_name: 'Start', urls: ['https://attacker.example/prompt'] }
      ]
    }
  end

  before do
    adapter = instance_double(Lla::Knowledge::SourceAdapter, discover: links)
    allow(Lla::Knowledge::SourceAdapter).to receive(:new).and_return(adapter)
    llm = instance_double(Captain::Llm::HelpCenterCurationService, perform: { message: message })
    allow(llm).to receive(:with_quota_idempotency_key).and_return(llm)
    allow(Captain::Llm::HelpCenterCurationService).to receive(:new).and_return(llm)
  end

  it 'keeps only exact discovered URLs and categories used by surviving articles' do
    plan = described_class.new(account: account, operation: operation).perform

    expect(plan.fetch('allowed_urls')).to eq(['https://docs.example.com/start'])
    expect(plan.fetch('categories')).to contain_exactly(include('name' => 'Start'))
    expect(plan.fetch('articles')).to contain_exactly(
      include('title' => 'Valid', 'urls' => ['https://docs.example.com/start'])
    )
  end

  it 'skips a provider result containing only invented URLs' do
    message[:articles].first[:urls] = ['https://attacker.example/prompt']

    expect { described_class.new(account: account, operation: operation).perform }
      .to raise_error(Onboarding::HelpCenterErrors::CurationSkipped, 'lla_knowledge_plan_below_minimum')
  end

  it 'skips before provider use when the tenant has no website origin' do
    portal.update!(homepage_link: nil)
    expect(Lla::Knowledge::SourceAdapter).not_to receive(:new)

    expect { described_class.new(account: account, operation: operation).perform }
      .to raise_error(Onboarding::HelpCenterErrors::CurationSkipped, 'lla_knowledge_website_missing')
  end
end
