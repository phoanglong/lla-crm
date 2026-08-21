require 'rails_helper'

RSpec.describe 'Zalo OA connections API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:bridge) { 'https://zbridge.test' }
  let(:connection_id) { 'ab12cd34ef' }
  let(:bridge_connection) do
    {
      'id' => connection_id,
      'name' => 'OA Nhà hàng Sen',
      'app_id' => '2222222222',
      'webhook_url' => "#{bridge}/webhook/zalo/c/#{connection_id}/tok",
      'chatwoot_webhook_url' => "#{bridge}/webhook/chatwoot/c/#{connection_id}",
      'oauth_url' => "#{bridge}/oauth/start?conn=#{connection_id}",
      'oauth_callback_url' => "#{bridge}/oauth/callback",
      'status' => { 'authorized' => false, 'webhook_received' => false, 'inbox_linked' => false }
    }
  end

  before do
    InstallationConfig.create!(name: 'ZALO_BRIDGE_URL', value: bridge)
    InstallationConfig.create!(name: 'ZALO_BRIDGE_ADMIN_TOKEN', value: 'bridge-admin-token')
    GlobalConfig.clear_cache
  end

  after { GlobalConfig.clear_cache }

  describe 'POST /api/v1/accounts/{account.id}/zalo/connections' do
    let(:params) { { connection: { name: 'OA Nhà hàng Sen', app_id: '2222222222', app_secret: 'app-secret-value' } } }

    it 'returns unauthorized for an unauthenticated request' do
      post "/api/v1/accounts/#{account.id}/zalo/connections", params: params

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses an agent: onboarding a channel is an administrator action' do
      post "/api/v1/accounts/#{account.id}/zalo/connections", params: params, headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
    end

    context 'when the bridge answers' do
      before do
        stub_request(:post, "#{bridge}/api/connections")
          .to_return(status: 201, body: bridge_connection.to_json, headers: { 'Content-Type' => 'application/json' })
        stub_request(:patch, "#{bridge}/api/connections/#{connection_id}")
          .to_return(status: 200, body: bridge_connection.merge('status' => bridge_connection['status'].merge('inbox_linked' => true)).to_json,
                     headers: { 'Content-Type' => 'application/json' })
      end

      it 'creates the inbox already wired to its own connection' do
        post "/api/v1/accounts/#{account.id}/zalo/connections", params: params, headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:created)
        body = response.parsed_body
        inbox = account.inboxes.find(body['inbox']['id'])
        channel = inbox.channel

        aggregate_failures do
          expect(inbox.name).to eq('OA Nhà hàng Sen')
          expect(channel).to be_a(Channel::Api)
          expect(channel.webhook_url).to eq("#{bridge}/webhook/chatwoot/c/#{connection_id}")
          expect(channel.additional_attributes).to include(
            'provider' => 'zalo_oa', 'zalo_connection_id' => connection_id, 'bridge_url' => bridge
          )
        end
      end

      it 'hands the bridge the inbox and its signing secret, and never the other way round' do
        post "/api/v1/accounts/#{account.id}/zalo/connections", params: params, headers: administrator.create_new_auth_token

        inbox = account.inboxes.last
        expect(
          a_request(:patch, "#{bridge}/api/connections/#{connection_id}").with do |request|
            payload = JSON.parse(request.body)
            payload['cw_inbox_id'] == inbox.id.to_s &&
              payload['cw_account_id'] == account.id.to_s &&
              payload['cw_url'] == ENV.fetch('FRONTEND_URL', '').chomp('/') &&
              payload['cw_webhook_secret'] == inbox.channel.secret
          end
        ).to have_been_made
        expect(response.body).not_to include(inbox.channel.secret)
      end

      it 'never lets the bridge admin token reach the browser' do
        post "/api/v1/accounts/#{account.id}/zalo/connections", params: params, headers: administrator.create_new_auth_token

        expect(response.body).not_to include('bridge-admin-token')
      end

      it 'answers with the checklist the wizard draws, all of it false at this point' do
        post "/api/v1/accounts/#{account.id}/zalo/connections", params: params, headers: administrator.create_new_auth_token

        checks = response.parsed_body['checks'].index_by { |check| check['key'] }
        aggregate_failures do
          expect(checks['inbox_created']['ok']).to be(true)
          expect(checks['oauth_authorized']['ok']).to be(false)
          expect(checks['message_received']['ok']).to be(false)
          expect(response.parsed_body['required_events']).to include('user_send_text', 'follow', 'unfollow')
        end
      end
    end

    it 'reports invalid app credentials instead of leaving a half-made inbox behind' do
      stub_request(:post, "#{bridge}/api/connections")
        .to_return(status: 422, body: { error: 'invalid_app_credentials' }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect do
        post "/api/v1/accounts/#{account.id}/zalo/connections",
             params: { connection: { name: 'OA', app_id: '1', app_secret: 'x' } },
             headers: administrator.create_new_auth_token
      end.not_to change(account.inboxes, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'says the bridge is not configured rather than failing obscurely' do
      InstallationConfig.find_by(name: 'ZALO_BRIDGE_ADMIN_TOKEN').update!(value: '')
      GlobalConfig.clear_cache

      post "/api/v1/accounts/#{account.id}/zalo/connections", params: params, headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body['error']).to include('Super Admin')
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/zalo/connections/{id}' do
    it 'reports every step as a measured fact' do
      stub_request(:get, "#{bridge}/api/connections/#{connection_id}")
        .to_return(status: 200,
                   body: bridge_connection.merge(
                     'inbox_id' => '0',
                     'status' => {
                       'authorized' => true, 'webhook_received' => true, 'inbox_linked' => true,
                       'outbound_secret_set' => true, 'last_inbound_at' => 1_700_000_000_000, 'last_outbound_at' => nil,
                       'oa' => { 'id' => '99', 'name' => 'Nhà hàng Sen' }
                     }
                   ).to_json,
                   headers: { 'Content-Type' => 'application/json' })

      get "/api/v1/accounts/#{account.id}/zalo/connections/#{connection_id}",
          headers: administrator.create_new_auth_token

      checks = response.parsed_body['checks'].index_by { |check| check['key'] }
      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(checks['oauth_authorized']['ok']).to be(true)
        expect(checks['message_received']['ok']).to be(true)
        expect(checks['message_sent']['ok']).to be(false)
        expect(checks['inbox_created']['ok']).to be(false)
        expect(response.parsed_body['connection']['status']['oa']['name']).to eq('Nhà hàng Sen')
      end
    end

    it 'answers 404 when the bridge has forgotten the connection' do
      stub_request(:get, "#{bridge}/api/connections/#{connection_id}").to_return(status: 404, body: '{}')

      get "/api/v1/accounts/#{account.id}/zalo/connections/#{connection_id}",
          headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/zalo/connections/domain_check' do
    let(:txt_records) do
      [
        instance_double(Resolv::DNS::Resource::IN::TXT, strings: ['zalo-platform-site-verification=abc123']),
        instance_double(Resolv::DNS::Resource::IN::TXT, strings: ['v=spf1 -all'])
      ]
    end

    it 'reports the verification codes actually published in DNS' do
      resolver = instance_double(Resolv::DNS, :timeouts= => 5, :getresources => txt_records)
      allow(Resolv::DNS).to receive(:open).and_yield(resolver)

      get "/api/v1/accounts/#{account.id}/zalo/connections/domain_check",
          params: { domain: 'Sen.vn', code: 'abc123' }, headers: administrator.create_new_auth_token

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to include('domain' => 'sen.vn', 'found' => true, 'matches' => true)
        expect(response.parsed_body['codes']).to eq(['abc123'])
      end
    end

    it 'rejects something that is not a domain' do
      get "/api/v1/accounts/#{account.id}/zalo/connections/domain_check",
          params: { domain: 'không phải tên miền' }, headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
