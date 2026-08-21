# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::FeatureRouter do
  let(:account) { create(:account) }

  describe '.resolve' do
    it 'returns the feature default without an account' do
      resolved = described_class.resolve(feature: 'editor')

      expect(resolved.except(:credential)).to eq(
        feature: 'editor',
        provider: 'openai',
        model: 'gpt-4.1-mini',
        source: :default
      )
    end

    it 'uses a valid account model override' do
      account.update!(captain_models: { 'editor' => 'gpt-4.1' })

      resolved = described_class.resolve(feature: 'editor', account: account)

      expect(resolved).to include(
        feature: 'editor',
        provider: 'openai',
        model: 'gpt-4.1',
        source: :account_override
      )
    end

    it 'resolves GPT-5.2 as the assistant default when Captain V2 is enabled without storing an account override' do
      account.enable_features!('captain_integration_v2')

      resolved = described_class.resolve(feature: 'assistant', account: account)

      expect(resolved).to include(
        feature: 'assistant',
        provider: 'openai',
        model: 'gpt-5.2',
        source: :default
      )
      expect(account.reload.captain_models).to be_nil
    end

    it 'keeps account model overrides ahead of the Captain V2 default' do
      account.enable_features!('captain_integration_v2')
      account.update!(captain_models: { 'assistant' => 'gpt-5.1' })

      resolved = described_class.resolve(feature: 'assistant', account: account)

      expect(resolved).to include(
        model: 'gpt-5.1',
        source: :account_override
      )
    end

    it 'falls back to the feature default when the account override is invalid' do
      account.captain_models = { 'editor' => 'invalid-model' }

      resolved = described_class.resolve(feature: 'editor', account: account)

      expect(resolved).to include(
        model: 'gpt-4.1-mini',
        source: :default
      )
    end

    it 'falls back to the feature default when the account override is blank' do
      account.update!(captain_models: { 'editor' => '' })

      resolved = described_class.resolve(feature: 'editor', account: account)

      expect(resolved).to include(
        model: 'gpt-4.1-mini',
        source: :default
      )
    end

    it 'raises for unknown features' do
      expect { described_class.resolve(feature: 'unknown_feature') }
        .to raise_error(described_class::UnknownFeatureError, 'Unknown LLM feature: unknown_feature')
    end

    # Danh mục mô hình của bản cài đặt không thể biết trước mọi mô hình khách sẽ chạy. Mô hình
    # `<nhà cung cấp>/<mô hình>` trỏ tới kết nối AI của chính tenant — và đó mới là điều làm
    # cho "mang AI của mình" có nghĩa.
    context 'when the account brought its own AI provider' do
      before do
        skip('encryption keys missing') unless Chatwoot.encryption_configured?
        account.lla_ai_providers.create!(kind: 'openai_compatible', name: 'noi-bo',
                                         api_base: 'https://llm.noi-bo.vn/v1', api_key: 'khoa-cua-khach')
        account.update!(captain_models: { 'editor' => 'noi-bo/llama-3.1-70b' })
      end

      it 'routes the feature to that connection' do
        resolved = described_class.resolve(feature: 'editor', account: account)

        aggregate_failures do
          expect(resolved[:model]).to eq('noi-bo/llama-3.1-70b')
          expect(resolved[:provider]).to eq('noi-bo')
          expect(resolved[:source]).to eq(:account_override)
          expect(resolved[:credential].api_key).to eq('khoa-cua-khach')
          expect(resolved[:credential].model).to eq('llama-3.1-70b')
        end
      end
    end
  end
end
