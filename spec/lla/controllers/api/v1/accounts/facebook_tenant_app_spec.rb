require 'rails_helper'

# Token do ứng dụng nào cấp thì phải đổi bằng ứng dụng đó. Tenant tự mang ứng dụng Meta mà
# hệ thống vẫn đổi token bằng cặp app id/secret của LLA thì Meta từ chối, và người dùng chỉ
# thấy "kết nối không thành công".
RSpec.describe 'Facebook page connect with a tenant-owned Meta app', type: :request do
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:oauth) { instance_double(Koala::Facebook::OAuth, exchange_access_token_info: { 'access_token' => 'long-lived' }) }

  before do
    create(:installation_config, name: 'FB_APP_ID', value: 'app-cua-nen-tang')
    create(:installation_config, name: 'FB_APP_SECRET', value: 'secret-cua-nen-tang')
    allow(Koala::Facebook::API).to receive(:new).and_return(instance_double(Koala::Facebook::API, get_connection: []))
  end

  after { GlobalConfig.clear_cache }

  it 'exchanges the token with the platform app when the tenant has none' do
    expect(Koala::Facebook::OAuth).to receive(:new).with('app-cua-nen-tang', 'secret-cua-nen-tang').and_return(oauth)

    post "/api/v1/accounts/#{account.id}/callbacks/facebook_pages",
         params: { omniauth_token: 'short-lived' }, headers: administrator.create_new_auth_token
  end

  it 'exchanges the token with the tenant own app once it has one' do
    skip_without_encryption
    Lla::PlatformApp.create!(account: account, platform: 'facebook', app_id: 'app-cua-tenant', app_secret: 'secret-cua-tenant')

    expect(Koala::Facebook::OAuth).to receive(:new).with('app-cua-tenant', 'secret-cua-tenant').and_return(oauth)

    post "/api/v1/accounts/#{account.id}/callbacks/facebook_pages",
         params: { omniauth_token: 'short-lived' }, headers: administrator.create_new_auth_token
  end

  it 'tells the dashboard which app to open the login dialog with' do
    skip_without_encryption
    Lla::PlatformApp.create!(account: account, platform: 'facebook', app_id: 'app-cua-tenant', app_secret: 'secret-cua-tenant')

    get "/api/v1/accounts/#{account.id}", headers: administrator.create_new_auth_token

    expect(response.parsed_body.dig('platform_apps', 'facebook', 'app_id')).to eq('app-cua-tenant')
    expect(response.body).not_to include('secret-cua-tenant')
  end
end
