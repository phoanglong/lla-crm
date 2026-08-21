require 'rails_helper'

RSpec.describe Lla::Captain::FirecrawlWebhookToken do
  let(:assistant) { create(:captain_assistant) }

  describe '.generate/.valid?' do
    it 'accepts a signed token for the same assistant and account' do
      token = described_class.generate(assistant)

      expect(described_class.valid?(token, assistant)).to be true
    end

    it 'rejects a token for another assistant' do
      token = described_class.generate(assistant)

      expect(described_class.valid?(token, create(:captain_assistant))).to be false
    end

    it 'rejects a modified token' do
      token = described_class.generate(assistant)

      expect(described_class.valid?("#{token}x", assistant)).to be false
    end

    it 'rejects an expired token' do
      token = described_class.generate(assistant)

      travel described_class::TTL + 1.second do
        expect(described_class.valid?(token, assistant)).to be false
      end
    end

    it 'rejects a configured signing secret that is too short' do
      previous = ENV.fetch('CAPTAIN_FIRECRAWL_WEBHOOK_SECRET', nil)
      ENV['CAPTAIN_FIRECRAWL_WEBHOOK_SECRET'] = 'short'

      expect { described_class.generate(assistant) }
        .to raise_error(described_class::ConfigurationError, 'CAPTAIN_FIRECRAWL_WEBHOOK_SECRET must be at least 32 bytes')
    ensure
      previous.nil? ? ENV.delete('CAPTAIN_FIRECRAWL_WEBHOOK_SECRET') : ENV['CAPTAIN_FIRECRAWL_WEBHOOK_SECRET'] = previous
    end
  end
end
