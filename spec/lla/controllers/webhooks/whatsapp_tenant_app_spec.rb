require 'rails_helper'

# Một tenant mang ứng dụng Meta của chính mình: từ lúc đó, chữ ký hợp lệ **chỉ** là chữ ký
# của ứng dụng ấy. Chấp nhận thêm chữ ký của ứng dụng nền tảng là xoá đúng cái ranh giới mà
# việc tự mang ứng dụng dựng lên.
RSpec.describe 'WhatsApp Cloud webhook with a tenant-owned Meta app', type: :request do
  let(:account) { create(:account) }
  let(:tenant_secret) { 'app-secret-cua-tenant' }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false,
                              provider_config: {
                                'api_key' => 'token', 'phone_number_id' => '1234', 'business_account_id' => '5678',
                                'app_secret' => tenant_secret
                              })
  end
  let(:payload) do
    { object: 'whatsapp_business_account',
      entry: [{ id: '5678', changes: [{ field: 'messages', value: { metadata: { phone_number_id: '1234' } } }] }] }.to_json
  end

  before { create(:installation_config, name: 'WHATSAPP_APP_SECRET', value: 'app-secret-cua-nen-tang') }

  after { GlobalConfig.clear_cache }

  def post_event(secret)
    post "/webhooks/whatsapp/#{channel.phone_number}",
         params: payload,
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'X-Hub-Signature-256' => "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, payload)}"
         }
  end

  it 'accepts an event signed by the tenant own app' do
    expect { post_event(tenant_secret) }.to have_enqueued_job(Webhooks::WhatsappEventsJob)

    expect(response).to have_http_status(:success)
  end

  it 'refuses an event signed by the platform app once the tenant brought its own' do
    expect { post_event('app-secret-cua-nen-tang') }.not_to have_enqueued_job(Webhooks::WhatsappEventsJob)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses an unsigned event' do
    post "/webhooks/whatsapp/#{channel.phone_number}", params: payload, headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end
end
