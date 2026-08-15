require 'rails_helper'

RSpec.describe Lla::CaptainConfigSeeder do
  describe '.perform' do
    it 'seeds installation configs from environment variables' do
      with_modified_env CAPTAIN_OPEN_AI_API_KEY: 'sk-lla-test', CAPTAIN_OPEN_AI_MODEL: 'gpt-4.1-mini' do
        described_class.perform
      end

      expect(InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY').value).to eq('sk-lla-test')
      expect(InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL').value).to eq('gpt-4.1-mini')
    end

    it 'overwrites a stale value — Infisical/ENV là nguồn sự thật' do
      InstallationConfig.create!(name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'sk-old')

      with_modified_env CAPTAIN_OPEN_AI_API_KEY: 'sk-new' do
        described_class.perform
      end

      expect(InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY').value).to eq('sk-new')
    end

    it 'does not touch configs whose environment variable is blank' do
      InstallationConfig.create!(name: 'CAPTAIN_OPEN_AI_ENDPOINT', value: 'https://openrouter.ai/api/v1')

      with_modified_env CAPTAIN_OPEN_AI_ENDPOINT: nil, CAPTAIN_OPEN_AI_API_KEY: nil do
        described_class.perform
      end

      expect(InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT').value).to eq('https://openrouter.ai/api/v1')
      expect(InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')).to be_nil
    end

    it 'is idempotent when values are unchanged' do
      with_modified_env CAPTAIN_OPEN_AI_API_KEY: 'sk-same' do
        described_class.perform
        config = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')
        updated_at = config.updated_at

        described_class.perform

        expect(config.reload.updated_at).to eq(updated_at)
      end
    end
  end
end
