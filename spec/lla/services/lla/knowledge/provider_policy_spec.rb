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

  # The reader used to be `ActiveModel::Type::Boolean`, which treats every string it
  # does not recognise as true and whose false list contains neither "no" nor "n".
  # `LLA_KNOWLEDGE_EXTERNAL_CRAWL_ENABLED=no` therefore switched the capability ON,
  # in the one class whose header calls itself a fail-closed gate.
  describe 'reading a capability flag' do
    # Spellings an operator would reasonably write, none of which means "on".
    %w[no No NO n off OFF false f 0 disabled nope DISABLED unset -].each do |value|
      it "treats #{value.inspect} as off" do
        with_modified_env('LLA_KNOWLEDGE_EXTERNAL_CRAWL_ENABLED' => value) do
          expect(described_class.capability_enabled?(:external_crawl)).to be(false)
        end
      end
    end

    %w[true True TRUE t yes y 1 on enabled].each do |value|
      it "treats #{value.inspect} as on" do
        with_modified_env('LLA_KNOWLEDGE_EXTERNAL_CRAWL_ENABLED' => value) do
          expect(described_class.capability_enabled?(:external_crawl)).to be(true)
        end
      end
    end

    it 'is off when the flag is absent' do
      with_modified_env('LLA_KNOWLEDGE_EXTERNAL_CRAWL_ENABLED' => nil) do
        expect(described_class.capability_enabled?(:external_crawl)).to be(false)
      end
    end

    it 'applies the same reading to the global egress switch' do
      with_modified_env('LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'no') do
        expect(described_class.global_egress_enabled?).to be(false)
      end
    end
  end

  describe 'reading a consent record' do
    def consent(enabled)
      account.update!(custom_attributes: account.custom_attributes.merge(
        'lla_provider_consents' => {
          'firecrawl' => { 'enabled' => enabled, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
        }
      ))
    end

    # Consent is a legal boundary. Only an unambiguous yes is one.
    ['no', 'n', 'off', 'false', '0', 'maybe', '', 'disabled', nil].each do |value|
      it "does not read #{value.inspect} as consent" do
        consent(value)
        expect(described_class.consented?(account, :firecrawl)).to be(false)
      end
    end

    it 'reads a real boolean true as consent' do
      consent(true)
      expect(described_class.consented?(account, :firecrawl)).to be(true)
    end

    it 'reads the string "true" as consent, because that is what a JSON API sends' do
      consent('true')
      expect(described_class.consented?(account, :firecrawl)).to be(true)
    end
  end

  it 'no longer declares a capability flag that nothing reads' do
    # `geo_restrictions` named LLA_WIDGET_GEO_RESTRICTIONS_ENABLED, which appeared in
    # no other file. The widget country policy is gated by LLA_WIDGET_GEOIP_ENABLED,
    # read permissively on purpose so an unparseable value keeps enforcing.
    expect(described_class::CAPABILITY_FLAGS).not_to have_key(:geo_restrictions)
    expect(described_class::CAPABILITY_FLAGS.values).to all(satisfy do |flag|
      Dir.glob(Rails.root.join('{app,lib,lla,enterprise}/**/*.rb')).any? { |f| File.read(f).include?(flag) }
    end)
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
