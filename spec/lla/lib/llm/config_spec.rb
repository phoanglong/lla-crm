require 'rails_helper'

# Điều kiện sống còn của "mỗi tenant một AI": hai tenant dùng hai nhà cung cấp khác nhau
# trong **cùng một tiến trình** mà không đè lên cấu hình của nhau. Trước đây `RubyLLM.configure`
# là cấu hình toàn cục, đặt một lần lúc khởi động — nên chỉ có đúng một câu trả lời cho cả máy.
RSpec.describe Llm::Config do
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'khoa-cua-lla')
    described_class.reset!
  end

  after { described_class.reset! }

  it 'builds a separate context per tenant call and leaves the process config alone' do
    skip_without_encryption
    account_a.lla_ai_providers.create!(kind: 'openai_compatible', name: 'a', api_base: 'https://a.vn/v1', api_key: 'khoa-a')
    account_b.lla_ai_providers.create!(kind: 'anthropic', name: 'b', api_key: 'khoa-b')

    seen = {}
    %w[a b].each_with_index do |name, index|
      account = index.zero? ? account_a : account_b
      credential = Lla::Ai::CredentialResolver.resolve(account: account, model: "#{name}/some-model")
      described_class.with_credential(credential) do |context|
        seen[name] = {
          openai: context.config.openai_api_key,
          openai_base: context.config.openai_api_base,
          anthropic: context.config.anthropic_api_key
        }
      end
    end

    aggregate_failures do
      expect(seen['a'][:openai]).to eq('khoa-a')
      expect(seen['a'][:openai_base]).to eq('https://a.vn/v1')
      expect(seen['b'][:anthropic]).to eq('khoa-b')
      # Khoá của tenant A không được rò sang lệnh gọi của tenant B.
      expect(seen['b'][:openai]).not_to eq('khoa-a')
      # Và cấu hình chung của tiến trình vẫn là khoá của bản cài đặt.
      expect(RubyLLM.config.openai_api_key).to eq('khoa-cua-lla')
    end
  end
end
