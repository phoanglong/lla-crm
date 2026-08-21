require 'rails_helper'

RSpec.describe 'Tenant AI providers API', type: :request do
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:params) do
    { provider: { name: 'noi-bo', kind: 'openai_compatible', api_base: 'https://llm.noi-bo.vn/v1',
                  api_key: 'khoa-cua-khach', models: ['llama-3.1-70b'] } }
  end

  describe 'POST /api/v1/accounts/{account.id}/ai/providers' do
    it 'refuses an agent: choosing the AI is an administrator decision' do
      post "/api/v1/accounts/#{account.id}/ai/providers", params: params, headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
    end

    it 'stores the connection and never echoes the key back' do
      skip_without_encryption
      post "/api/v1/accounts/#{account.id}/ai/providers", params: params, headers: administrator.create_new_auth_token

      aggregate_failures do
        expect(response).to have_http_status(:created)
        expect(response.parsed_body).to include('name' => 'noi-bo', 'api_key_configured' => true)
        expect(response.parsed_body['models']).to eq(['llama-3.1-70b'])
        expect(response.body).not_to include('khoa-cua-khach')
      end
    end

    it 'refuses an endpoint that is not https' do
      skip_without_encryption
      post "/api/v1/accounts/#{account.id}/ai/providers",
           params: { provider: params[:provider].merge(api_base: 'http://llm.noi-bo.vn/v1') },
           headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'refuses a name that would break the provider/model separator' do
      skip_without_encryption
      post "/api/v1/accounts/#{account.id}/ai/providers",
           params: { provider: params[:provider].merge(name: 'noi/bo') },
           headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/ai/providers/{name}' do
    it 'keeps the stored key when the form submits an empty one' do
      skip_without_encryption
      provider = account.lla_ai_providers.create!(kind: 'openai', name: 'rieng', api_key: 'giu-nguyen')

      patch "/api/v1/accounts/#{account.id}/ai/providers/rieng",
            params: { provider: { api_key: '', models: %w[gpt-4.1] } },
            headers: administrator.create_new_auth_token

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(provider.reload.api_key).to eq('giu-nguyen')
        expect(provider.model_names).to eq(['gpt-4.1'])
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/ai/providers/{name}/verify' do
    let!(:provider) do
      skip_without_encryption
      account.lla_ai_providers.create!(kind: 'openai_compatible', name: 'noi-bo',
                                       api_base: 'https://llm.noi-bo.vn/v1', api_key: 'k')
    end

    it 'calls the provider for real and records that it answered' do
      stub_request(:get, 'https://llm.noi-bo.vn/v1/models')
        .to_return(status: 200, body: { data: [{ id: 'llama-3.1-70b' }, { id: 'qwen2.5' }] }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/ai/providers/noi-bo/verify", headers: administrator.create_new_auth_token

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body['models']).to eq(%w[llama-3.1-70b qwen2.5])
        expect(provider.reload.verified_at).to be_present
        expect(provider.last_error).to be_nil
      end
    end

    # Mô hình của cổng LLM mang sẵn dấu `/` trong tên (`z-ai/glm-5.3`). Nếu danh sách ấy bị từ
    # chối thì kết nối hiện là "đã kiểm tra" nhưng không có mô hình nào chọn được — nghĩa là
    # "mang AI của mình" hỏng đúng ở trường hợp phổ biến nhất.
    it 'keeps gateway model ids that contain a slash, and stores them' do
      stub_request(:get, 'https://llm.noi-bo.vn/v1/models')
        .to_return(status: 200, body: { data: [{ id: 'z-ai/glm-5.3' }, { id: 'meta-llama/llama-3.1-70b' }] }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/ai/providers/noi-bo/verify", headers: administrator.create_new_auth_token

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body['models']).to eq(['z-ai/glm-5.3', 'meta-llama/llama-3.1-70b'])
        expect(provider.reload.model_names).to eq(['z-ai/glm-5.3', 'meta-llama/llama-3.1-70b'])
      end
    end

    it 'reports a refused key instead of pretending the connection works' do
      stub_request(:get, 'https://llm.noi-bo.vn/v1/models').to_return(status: 401, body: '{}')

      post "/api/v1/accounts/#{account.id}/ai/providers/noi-bo/verify", headers: administrator.create_new_auth_token

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq('HTTP 401')
        expect(provider.reload.verified_at).to be_nil
        expect(provider.last_error).to eq('HTTP 401')
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/ai/providers' do
    it 'shows only this tenant connections' do
      skip_without_encryption
      account.lla_ai_providers.create!(kind: 'openai', name: 'cua-toi', api_key: 'k')
      create(:account).lla_ai_providers.create!(kind: 'openai', name: 'cua-nguoi-khac', api_key: 'k')

      get "/api/v1/accounts/#{account.id}/ai/providers", headers: administrator.create_new_auth_token

      expect(response.parsed_body['providers'].pluck('name')).to eq(['cua-toi'])
    end
  end
end
