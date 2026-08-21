module InstagramConcern
  extend ActiveSupport::Concern

  def instagram_client
    ::OAuth2::Client.new(
      client_id,
      client_secret,
      {
        site: 'https://api.instagram.com',
        authorize_url: 'https://api.instagram.com/oauth/authorize',
        token_url: 'https://api.instagram.com/oauth/access_token',
        auth_scheme: :request_body,
        token_method: :post
      }
    )
  end

  private

  # Tenant tự mang ứng dụng Instagram thì mọi bước OAuth phải dùng ứng dụng ấy: mã uỷ quyền
  # do ứng dụng nào cấp thì chỉ ứng dụng đó đổi được ra token.
  # `instagram_oauth_account` do lớp con cung cấp — phía tenant là `Current.account`, phía
  # callback là tài khoản đọc ra từ `state`.
  def tenant_instagram_app
    account = respond_to?(:instagram_oauth_account, true) ? instagram_oauth_account : nil
    return if account.blank?

    account.lla_platform_apps.find_by(platform: 'instagram')
  end

  def client_id
    tenant_instagram_app&.app_id.presence || GlobalConfigService.load('INSTAGRAM_APP_ID', nil)
  end

  def client_secret
    tenant_instagram_app&.app_secret.presence || GlobalConfigService.load('INSTAGRAM_APP_SECRET', nil)
  end

  def exchange_for_long_lived_token(short_lived_token)
    endpoint = 'https://graph.instagram.com/access_token'
    params = {
      grant_type: 'ig_exchange_token',
      client_secret: client_secret,
      access_token: short_lived_token,
      client_id: client_id
    }

    make_api_request(endpoint, params, 'Failed to exchange token')
  end

  def fetch_instagram_user_details(access_token)
    endpoint = 'https://graph.instagram.com/v22.0/me'
    params = {
      fields: 'id,username,user_id,name,profile_picture_url,account_type',
      access_token: access_token
    }

    make_api_request(endpoint, params, 'Failed to fetch Instagram user details')
  end

  def make_api_request(endpoint, params, error_prefix)
    response = HTTParty.get(
      endpoint,
      query: params,
      headers: { 'Accept' => 'application/json' }
    )

    unless response.success?
      Rails.logger.error "#{error_prefix}. Status: #{response.code}, Body: #{response.body}"
      raise "#{error_prefix}: #{response.body}"
    end

    begin
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      ChatwootExceptionTracker.new(e).capture_exception
      Rails.logger.error "Invalid JSON response: #{response.body}"
      raise e
    end
  end

  def base_url
    ENV.fetch('FRONTEND_URL', 'http://localhost:3000')
  end
end
