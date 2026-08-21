require 'rails_helper'

RSpec.describe 'Super Admin channel providers', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/channel_providers' do
    it 'requires super admin authentication' do
      get '/super_admin/channel_providers'

      expect(response).to have_http_status(:redirect)
    end

    it 'shows provider configuration metadata without secret values' do
      create(:installation_config, name: 'ZALO_BRIDGE_URL', value: 'https://zbridge.example.com')
      create(:installation_config, name: 'FB_APP_SECRET', value: 'must-not-appear-in-html')
      create(:channel_api, webhook_url: 'https://zbridge.example.com/webhook/chatwoot')
      create(:account).disable_features!('channel_facebook')
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/channel_providers'

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Zalo OA', 'Facebook Messenger', 'Có hộp thư')
      expect(response.body).to include('channel_facebook', 'Tenant đã bật')
      expect(response.body).not_to include('must-not-appear-in-html')
    end

    # Bảng này từng chỉ nói về bản cài đặt. Với mô hình SaaS, một kênh có thể chưa cấu hình ở
    # cấp cài đặt mà vẫn đang chạy — vì tenant mang ứng dụng của chính họ.
    it 'reports a channel as live when a tenant brought its own app' do
      skip('encryption keys missing') unless Chatwoot.encryption_configured?
      Lla::PlatformApp.create!(account: create(:account), platform: 'facebook', app_id: '1', app_secret: 's')
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/channel_providers'

      expect(response.body).to include('Tenant tự khai')
    end
  end
end
