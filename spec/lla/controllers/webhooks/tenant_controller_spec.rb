require 'rails_helper'

RSpec.describe 'Tenant platform webhooks', type: :request do
  def skip_without_encryption
    skip('encryption keys missing; credential examples run in the encryption-enabled suite') unless Chatwoot.encryption_configured?
  end

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:secret) { 'secret-cua-tenant-a' }
  let(:platform_app) do
    create_app(account: account, app_id: '111', app_secret: secret)
  end
  let(:payload) do
    {
      object: 'page',
      entry: [{
        id: 'page-1',
        messaging: [{
          sender: { id: 'u-1' }, recipient: { id: 'page-1' }, timestamp: 1_700_000_000_000,
          message: { mid: 'mid.1', text: 'xin chào' }
        }]
      }]
    }.to_json
  end

  def create_app(account:, app_id:, app_secret:)
    skip_without_encryption
    Lla::PlatformApp.create!(account: account, platform: 'facebook', app_id: app_id, app_secret: app_secret)
  end

  def meta_signature(body, key)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', key, body)}"
  end

  def post_event(app, body: payload, signature: nil)
    post "/webhooks/tenant/facebook/#{app.webhook_token}",
         params: body,
         headers: { 'CONTENT_TYPE' => 'application/json' }.merge(signature ? { 'X-Hub-Signature-256' => signature } : {})
  end

  describe 'GET (nền tảng gọi khi lưu URL)' do
    it 'returns the challenge for the tenant own verify token' do
      get "/webhooks/tenant/facebook/#{platform_app.webhook_token}",
          params: { 'hub.mode' => 'subscribe', 'hub.verify_token' => platform_app.verify_token, 'hub.challenge' => '99887' }

      expect(response).to have_http_status(:success)
      expect(response.body).to eq('99887')
    end

    it 'refuses another tenant verify token' do
      other = create_app(account: other_account, app_id: '222', app_secret: 'khac')

      get "/webhooks/tenant/facebook/#{platform_app.webhook_token}",
          params: { 'hub.verify_token' => other.verify_token, 'hub.challenge' => '99887' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'POST' do
    it 'refuses an unsigned event' do
      post_event(platform_app)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses an event signed with another tenant secret' do
      post_event(platform_app, signature: meta_signature(payload, 'secret-cua-tenant-b'))

      expect(response).to have_http_status(:unauthorized)
    end

    it 'accepts an event signed with this tenant own secret and carries the account with it' do
      expect do
        post_event(platform_app, signature: meta_signature(payload, secret))
      end.to have_enqueued_job(Webhooks::FacebookEventsJob).with(anything, account.id)

      expect(response).to have_http_status(:success)
      expect(platform_app.reload.last_event_at).to be_present
    end

    it 'answers 404 for a token nobody owns' do
      post "/webhooks/tenant/facebook/#{'0' * 48}", params: payload, headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 when the token belongs to a different platform' do
      skip_without_encryption
      post "/webhooks/tenant/instagram/#{platform_app.webhook_token}",
           params: payload, headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:not_found)
    end
  end

  # Đây là điều kiện sống còn của mô hình SaaS: hai tenant có thể nối cùng một Page (thật hoặc
  # do một bên khai gian), và tin của người này không được rơi sang người kia. Đường cũ đoán
  # tenant từ `page_id` toàn cục nên nó nhân đôi; đường của tenant thì không.
  describe 'cách ly giữa hai tenant', type: :request do
    it 'delivers only into the tenant whose webhook received the event' do
      skip_without_encryption
      # Tạo channel Facebook sẽ gọi Graph API để đăng ký nhận sự kiện — không liên quan tới
      # điều đang kiểm, chỉ cần nó không bắn ra mạng.
      stub_request(:post, %r{graph\.facebook\.com/.*/subscribed_apps}).to_return(status: 200, body: '{"success":true}')
      # Dựng liên hệ sẽ hỏi Graph API hồ sơ người gửi; ở đây chỉ cần nó trả lời gì đó.
      stub_request(:get, %r{graph\.facebook\.com/u-1}).to_return(
        status: 200, body: { first_name: 'Khách', last_name: 'Thử', profile_pic: '' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
      channel_a = create(:channel_facebook_page, account: account, page_id: 'page-1')
      channel_b = create(:channel_facebook_page, account: other_account, page_id: 'page-1')
      inbox_a = channel_a.inbox
      inbox_b = channel_b.inbox

      perform_enqueued_jobs(only: Webhooks::FacebookEventsJob) do
        post_event(platform_app, signature: meta_signature(payload, secret))
      end

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(inbox_a.reload.messages.pluck(:content)).to eq(['xin chào'])
        expect(inbox_b.reload.messages).to be_empty
      end
    end
  end
end
