require 'rails_helper'

RSpec.describe Lla::Ai::CredentialResolver do
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  let(:account) { create(:account) }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'khoa-cua-lla')
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_ENDPOINT', value: 'https://api.openai.com')
  end

  it 'falls back to the installation key for a catalogue model' do
    credential = described_class.resolve(account: account, model: 'gpt-4.1-mini')

    aggregate_failures do
      expect(credential.source).to eq(:system)
      expect(credential.api_key).to eq('khoa-cua-lla')
      expect(credential.model).to eq('gpt-4.1-mini')
      expect(credential.kind).to eq('openai')
    end
  end

  it 'uses the tenant own connection when the model names it' do
    skip_without_encryption
    account.lla_ai_providers.create!(kind: 'openai_compatible', name: 'noi-bo',
                                     api_base: 'https://llm.noi-bo.vn/v1', api_key: 'khoa-cua-khach')

    credential = described_class.resolve(account: account, model: 'noi-bo/llama-3.1-70b')

    aggregate_failures do
      expect(credential.source).to eq(:account)
      expect(credential.api_key).to eq('khoa-cua-khach')
      expect(credential.api_base).to eq('https://llm.noi-bo.vn/v1')
      # Tên nhà cung cấp bị bóc ra; cái gửi đi là tên mô hình thật.
      expect(credential.model).to eq('llama-3.1-70b')
      expect(credential.kind).to eq('openai_compatible')
    end
  end

  it 'keeps a slash inside the model name of a gateway intact' do
    skip_without_encryption
    account.lla_ai_providers.create!(kind: 'openai_compatible', name: 'router',
                                     api_base: 'https://openrouter.ai/api/v1', api_key: 'k')

    credential = described_class.resolve(account: account, model: 'router/meta-llama/llama-3.1-70b-instruct')

    expect(credential.model).to eq('meta-llama/llama-3.1-70b-instruct')
  end

  it 'does not reach into another tenant connection' do
    skip_without_encryption
    other = create(:account)
    other.lla_ai_providers.create!(kind: 'openai', name: 'noi-bo', api_key: 'khoa-cua-tenant-khac')

    credential = described_class.resolve(account: account, model: 'noi-bo/gpt-4.1')

    aggregate_failures do
      expect(credential.source).to eq(:system)
      expect(credential.api_key).to eq('khoa-cua-lla')
    end
  end

  it 'ignores a disabled connection rather than failing the call' do
    skip_without_encryption
    account.lla_ai_providers.create!(kind: 'openai', name: 'tam-tat', api_key: 'k', enabled: false)

    expect(described_class.resolve(account: account, model: 'tam-tat/gpt-4.1').source).to eq(:system)
  end
end
