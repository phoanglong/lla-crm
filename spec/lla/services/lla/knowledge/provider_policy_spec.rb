require 'rails_helper'

RSpec.describe Lla::Knowledge::ProviderPolicy do
  let(:account) { create(:account) }

  it 'denies external egress by default' do
    expect(described_class.egress_permitted?(
             account: account, provider: :firecrawl, capability: :external_crawl
           )).to be(false)
  end

  it 'requires the global switch, capability switch, and tenant consent together' do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'firecrawl' => { 'enabled' => true, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
      }
    ))

    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_EXTERNAL_CRAWL_ENABLED' => 'true'
    ) do
      expect(described_class.egress_permitted?(
               account: account, provider: :firecrawl, capability: :external_crawl
             )).to be(true)
      expect(described_class.consent_digest(account, :firecrawl)).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  it 'rejects a legacy boolean without versioned consent evidence' do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => { 'firecrawl' => true }
    ))

    expect(described_class.consented?(account, :firecrawl)).to be(false)
  end

  it 'returns a stable denial code without provider details' do
    expect do
      described_class.authorize_egress!(
        account: account, provider: :openai, capability: :article_generation
      )
    end.to raise_error(described_class::Denied) { |error| expect(error.code).to eq('lla_knowledge_provider_disabled') }
  end

  it 'rejects unregistered providers' do
    expect do
      described_class.egress_permitted?(account: account, provider: :attacker, capability: :external_crawl)
    end.to raise_error(ArgumentError, /unknown LLA Knowledge provider/)
  end
end
