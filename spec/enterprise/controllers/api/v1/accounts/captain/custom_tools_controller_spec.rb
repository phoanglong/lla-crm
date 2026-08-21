require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::CustomTools', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  around do |example|
    previous_value = ENV.fetch(Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG, nil)
    ENV[Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG] = 'true'
    example.run
  ensure
    previous_value.nil? ? ENV.delete(Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG) : ENV[Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG] = previous_value
  end

  before { account.enable_features!('custom_tools') }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/custom_tools' do
    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/captain/custom_tools"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns success status' do
        create_list(:captain_custom_tool, 3, account: account)
        get "/api/v1/accounts/#{account.id}/captain/custom_tools",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(3)
      end
    end

    context 'when it is an admin' do
      it 'returns success status and custom tools' do
        create_list(:captain_custom_tool, 5, account: account)
        get "/api/v1/accounts/#{account.id}/captain/custom_tools",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(5)
        expect(json_response[:payload].first[:auth_config]).to eq({})
        expect(json_response[:payload].first[:auth_configured]).to be(false)
      end

      it 'returns all custom tools including disabled' do
        create(:captain_custom_tool, account: account, enabled: true)
        create(:captain_custom_tool, account: account, enabled: false)
        get "/api/v1/accounts/#{account.id}/captain/custom_tools",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(2)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/custom_tools/test' do
    let(:test_attributes) do
      {
        custom_tool: {
          title: 'Test External API',
          endpoint_url: 'https://example.com/health',
          http_method: 'GET',
          auth_type: 'none',
          enabled: true
        }
      }
    end

    before do
      allow(Lla::Network::UrlSafety).to receive(:validate!) do |url|
        Lla::Network::UrlSafety::Result.new(uri: URI.parse(url), ip_address: '93.184.216.34')
      end
    end

    it 'allows an administrator to test a valid tool without returning the upstream body' do
      stub_request(:get, 'https://example.com/health')
        .to_return(status: 200, body: 'sensitive-upstream-body', headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
           params: test_attributes,
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to eq(status: 200, response_bytes: 23, content_type: 'application/json')
      expect(response.body).not_to include('sensitive-upstream-body')
    end

    it 'rejects an agent before making the outbound request' do
      request = stub_request(:get, 'https://example.com/health')

      post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
           params: test_attributes,
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(request).not_to have_been_requested
    end

    it 'returns a generic error without leaking the upstream failure' do
      stub_request(:get, 'https://example.com/health').to_raise(StandardError.new('upstream-secret-value'))

      post "/api/v1/accounts/#{account.id}/captain/custom_tools/test",
           params: test_attributes,
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response).to eq(error: 'Custom tool test failed')
      expect(response.body).not_to include('upstream-secret-value')
    end
  end

  describe 'deployment kill switch' do
    it 'rejects access when the global custom-tool switch is disabled' do
      ENV[Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG] = 'false'

      get "/api/v1/accounts/#{account.id}/captain/custom_tools",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:forbidden)
      expect(json_response).to eq(error: 'Custom tools are not enabled for this account')
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/custom_tools/{id}' do
    let(:custom_tool) { create(:captain_custom_tool, account: account) }

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns success status and custom tool' do
        get "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:id]).to eq(custom_tool.id)
        expect(json_response[:title]).to eq(custom_tool.title)
      end
    end

    context 'when custom tool does not exist' do
      it 'returns not found status' do
        get "/api/v1/accounts/#{account.id}/captain/custom_tools/999999",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/custom_tools' do
    let(:valid_attributes) do
      {
        custom_tool: {
          title: 'Fetch Order Status',
          description: 'Fetches order status from external API',
          endpoint_url: 'https://api.example.com/orders/{{ order_id }}',
          http_method: 'GET',
          enabled: true,
          param_schema: [
            { name: 'order_id', type: 'string', description: 'The order ID', required: true }
          ]
        }
      }
    end

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: valid_attributes
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: valid_attributes,
             headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'creates a new custom tool and returns success status' do
        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: valid_attributes,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:title]).to eq('Fetch Order Status')
        expect(json_response[:description]).to eq('Fetches order status from external API')
        expect(json_response[:enabled]).to be(true)
        expect(json_response[:slug]).to eq('custom_fetch_order_status')
        expect(json_response[:param_schema]).to eq([
                                                     { name: 'order_id', type: 'string', description: 'The order ID', required: true }
                                                   ])
      end

      it 'never returns stored credentials to an administrator' do
        skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
        secret_attributes = valid_attributes.deep_dup
        secret_attributes[:custom_tool].merge!(auth_type: 'bearer', auth_config: { token: 'dummy-controller-token' })

        post "/api/v1/accounts/#{account.id}/captain/custom_tools",
             params: secret_attributes,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:auth_config]).to eq({})
        expect(json_response[:auth_configured]).to be(true)
        expect(response.body).not_to include('dummy-controller-token')
      end

      context 'with invalid parameters' do
        let(:invalid_attributes) do
          {
            custom_tool: {
              title: '',
              endpoint_url: ''
            }
          }
        end

        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/captain/custom_tools",
               params: invalid_attributes,
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
        end
      end

      context 'with invalid endpoint URL' do
        let(:invalid_url_attributes) do
          {
            custom_tool: {
              title: 'Test Tool',
              endpoint_url: 'http://localhost/api',
              http_method: 'GET'
            }
          }
        end

        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/captain/custom_tools",
               params: invalid_url_attributes,
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_entity)
        end
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/captain/custom_tools/{id}' do
    let(:custom_tool) { create(:captain_custom_tool, account: account) }
    let(:update_attributes) do
      {
        custom_tool: {
          title: 'Updated Tool Title',
          enabled: false
        }
      }
    end

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: update_attributes
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: update_attributes,
              headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'updates the custom tool and returns success status' do
        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: update_attributes,
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:title]).to eq('Updated Tool Title')
        expect(json_response[:enabled]).to be(false)
      end

      it 'preserves an encrypted credential when an update omits the secret value' do
        skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
        custom_tool.update!(auth_type: 'bearer', auth_config: { token: 'dummy-preserved-token' })

        patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
              params: { custom_tool: { title: 'Credential Preserved', auth_type: 'bearer', auth_config: {} } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(custom_tool.reload.auth_config).to eq('token' => 'dummy-preserved-token')
        expect(response.body).not_to include('dummy-preserved-token')
      end

      context 'with invalid parameters' do
        let(:invalid_attributes) do
          {
            custom_tool: {
              title: ''
            }
          }
        end

        it 'returns unprocessable entity status' do
          patch "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
                params: invalid_attributes,
                headers: admin.create_new_auth_token,
                as: :json

          expect(response).to have_http_status(:unprocessable_entity)
        end
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/captain/custom_tools/{id}' do
    let!(:custom_tool) { create(:captain_custom_tool, account: account) }

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        delete "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized status' do
        delete "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
               headers: agent.create_new_auth_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'deletes the custom tool and returns no content status' do
        expect do
          delete "/api/v1/accounts/#{account.id}/captain/custom_tools/#{custom_tool.id}",
                 headers: admin.create_new_auth_token
        end.to change(Captain::CustomTool, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end

      context 'when custom tool does not exist' do
        it 'returns not found status' do
          delete "/api/v1/accounts/#{account.id}/captain/custom_tools/999999",
                 headers: admin.create_new_auth_token

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
