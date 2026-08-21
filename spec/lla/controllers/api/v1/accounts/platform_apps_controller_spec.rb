require 'rails_helper'

RSpec.describe 'Tenant platform apps API', type: :request do
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:params) { { platform_app: { platform: 'facebook', app_id: '123456789', app_secret: 'secret-cua-khach' } } }

  describe 'POST /api/v1/accounts/{account.id}/platform_apps' do
    it 'refuses an agent: connecting a platform is an administrator action' do
      post "/api/v1/accounts/#{account.id}/platform_apps", params: params, headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
    end

    it 'hands back the webhook URL and verify token to paste into the platform' do
      skip_without_encryption
      post "/api/v1/accounts/#{account.id}/platform_apps", params: params, headers: administrator.create_new_auth_token

      body = response.parsed_body
      aggregate_failures do
        expect(response).to have_http_status(:created)
        expect(body['webhook_url']).to include('/webhooks/tenant/facebook/')
        expect(body['verify_token']).to be_present
        expect(body['app_secret_configured']).to be(true)
      end
    end

    # Secret của khách đi vào một chiều. Trả nó ra lại là biến mỗi lần mở trang thành một
    # cơ hội rò rỉ, mà chẳng để làm gì.
    it 'never echoes the app secret back' do
      skip_without_encryption
      post "/api/v1/accounts/#{account.id}/platform_apps", params: params, headers: administrator.create_new_auth_token

      expect(response.body).not_to include('secret-cua-khach')
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/platform_apps/{platform}' do
    it 'keeps the stored secret when the form submits an empty one' do
      skip_without_encryption
      app = Lla::PlatformApp.create!(account: account, platform: 'facebook', app_id: '1', app_secret: 'giu-nguyen')

      patch "/api/v1/accounts/#{account.id}/platform_apps/facebook",
            params: { platform_app: { app_id: '2', app_secret: '' } },
            headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(app.reload.app_id).to eq('2')
      expect(app.app_secret).to eq('giu-nguyen')
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/platform_apps' do
    it 'shows only this tenant apps' do
      skip_without_encryption
      Lla::PlatformApp.create!(account: account, platform: 'facebook', app_id: '1', app_secret: 's')
      Lla::PlatformApp.create!(account: create(:account), platform: 'facebook', app_id: '2', app_secret: 's')

      get "/api/v1/accounts/#{account.id}/platform_apps", headers: administrator.create_new_auth_token

      expect(response.parsed_body.pluck('app_id')).to eq(['1'])
    end
  end
end
