require 'rails_helper'

RSpec.describe Lla::Ai::Provider do
  # Không có khoá mã hoá thì model từ chối giữ khoá của khách — đó là hành vi đúng, nên các
  # ví dụ cần khoá chỉ chạy ở bộ có bật mã hoá.
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  let(:account) { create(:account) }

  # Đây là khoá của KHÁCH. Nằm plaintext trong CSDL là một sự đánh đổi không được phép xảy ra
  # trong im lặng.
  it 'stores the api key encrypted, not as readable text' do
    skip_without_encryption

    provider = described_class.create!(account: account, kind: 'openai', name: 'rieng', api_key: 'khong-duoc-doc-duoc')
    raw = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql(['SELECT api_key FROM lla_ai_providers WHERE id = ?', provider.id])
    )

    aggregate_failures do
      expect(raw).not_to include('khong-duoc-doc-duoc')
      expect(provider.reload.api_key).to eq('khong-duoc-doc-duoc')
    end
  end

  it 'refuses to hold a customer key when encryption is not configured' do
    allow(Chatwoot).to receive(:encryption_configured?).and_return(false)

    provider = described_class.new(account: account, kind: 'openai', name: 'rieng', api_key: 'plaintext')

    aggregate_failures do
      expect(provider).not_to be_valid
      expect(provider.errors[:api_key]).to be_present
    end
  end

  it 'gives one tenant one connection per name' do
    skip_without_encryption
    described_class.create!(account: account, kind: 'openai', name: 'rieng', api_key: 'k')

    expect do
      described_class.create!(account: account, kind: 'anthropic', name: 'rieng', api_key: 'k')
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  # Tên kết nối đi vào định danh mô hình `<tên>/<mô hình>`, nên dấu `/` trong tên sẽ làm
  # `CredentialResolver` tách sai.
  it 'refuses a connection name that would break the model identifier' do
    skip_without_encryption

    expect(described_class.new(account: account, kind: 'openai', name: 'co/dau', api_key: 'k')).not_to be_valid
  end

  # Ngược lại, tên **mô hình** thì được phép có dấu `/`: cổng LLM nào cũng đặt tên kiểu
  # `z-ai/glm-5.3`, và chỉ dấu `/` đầu tiên trong `<tên>/<mô hình>` là ký tự ngăn cách.
  it 'keeps gateway model names that contain a slash' do
    skip_without_encryption

    provider = described_class.create!(account: account, kind: 'openai_compatible', name: 'cong',
                                       api_base: 'https://openrouter.ai/api/v1', api_key: 'k',
                                       models: ['z-ai/glm-5.3'])

    aggregate_failures do
      expect(provider.reload.model_names).to eq(['z-ai/glm-5.3'])
      expect(described_class::MAX_MODELS).to be >= 200
    end
  end

  it 'refuses an endpoint that is not https, or that carries credentials in the url' do
    skip_without_encryption

    aggregate_failures do
      expect(described_class.new(account: account, kind: 'openai_compatible', name: 'a', api_base: 'http://x/v1', api_key: 'k')).not_to be_valid
      expect(described_class.new(account: account, kind: 'openai_compatible', name: 'b', api_base: 'https://u:p@x/v1', api_key: 'k')).not_to be_valid
      expect(described_class.new(account: account, kind: 'openai_compatible', name: 'c', api_base: nil, api_key: 'k')).not_to be_valid
    end
  end
end
