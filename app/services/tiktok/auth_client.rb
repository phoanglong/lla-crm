class Tiktok::AuthClient
  REQUIRED_SCOPES = %w[user.info.basic user.info.username user.info.stats user.info.profile user.account.type user.insights message.list.read
                       message.list.send message.list.manage].freeze

  class << self
    def authorize_url(state: nil, account: nil)
      credentials = credentials_for(account)
      tiktok_client = ::OAuth2::Client.new(
        credentials[:id],
        credentials[:secret],
        {
          site: 'https://www.tiktok.com',
          authorize_url: '/v2/auth/authorize',
          auth_scheme: :basic_auth
        }
      )

      tiktok_client.authorize_url(
        {
          response_type: 'code',
          client_key: credentials[:id],
          redirect_uri: redirect_uri,
          scope: REQUIRED_SCOPES.join(','),
          state: state
        }
      )
    end

    # https://business-api.tiktok.com/portal/docs?id=1832184159540418
    def obtain_short_term_access_token(auth_code, account: nil) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      credentials = credentials_for(account)
      endpoint = "#{api_base_url}/tt_user/oauth2/token/"
      headers = { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }
      body = {
        client_id: credentials[:id],
        client_secret: credentials[:secret],
        grant_type: 'authorization_code',
        auth_code: auth_code,
        redirect_uri: redirect_uri
      }

      response = HTTParty.post(
        endpoint,
        body: body.to_json,
        headers: headers
      )

      json = process_json_response(response, 'Failed to obtain TikTok short-term access token')

      {
        business_id: json['data']['open_id'],
        scope: json['data']['scope'],
        access_token: json['data']['access_token'],
        refresh_token: json['data']['refresh_token'],
        expires_at: Time.current + json['data']['expires_in'].seconds,
        refresh_token_expires_at: Time.current + json['data']['refresh_token_expires_in'].seconds
      }.with_indifferent_access
    end

    def renew_short_term_access_token(refresh_token) # rubocop:disable Metrics/MethodLength
      endpoint = "#{api_base_url}/tt_user/oauth2/refresh_token/"
      headers = { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }
      body = {
        client_id: client_id,
        client_secret: client_secret,
        grant_type: 'refresh_token',
        refresh_token: refresh_token
      }

      response = HTTParty.post(
        endpoint,
        body: body.to_json,
        headers: headers
      )

      json = process_json_response(response, 'Failed to renew TikTok short-term access token')

      {
        access_token: json['data']['access_token'],
        refresh_token: json['data']['refresh_token'],
        expires_at: Time.current + json['data']['expires_in'].seconds,
        refresh_token_expires_at: Time.current + json['data']['refresh_token_expires_in'].seconds
      }.with_indifferent_access
    end

    def webhook_callback
      endpoint = "#{api_base_url}/business/webhook/list/"
      headers = { Accept: 'application/json' }
      params = {
        app_id: client_id,
        secret: client_secret,
        event_type: 'DIRECT_MESSAGE'
      }
      response = HTTParty.get(endpoint, query: params, headers: headers)

      process_json_response(response, 'Failed to fetch TikTok webhook callback')
    end

    # Callback URL đăng ký **theo ứng dụng**. Tenant mang ứng dụng riêng thì đăng ký đúng
    # đường webhook riêng của họ, chứ không phải đường dùng chung.
    def update_webhook_callback(account: nil)
      credentials = credentials_for(account)
      endpoint = "#{api_base_url}/business/webhook/update/"
      headers = { Accept: 'application/json', 'Content-Type': 'application/json' }
      body = {
        app_id: credentials[:id],
        secret: credentials[:secret],
        event_type: 'DIRECT_MESSAGE',
        callback_url: credentials[:webhook_url]
      }
      response = HTTParty.post(endpoint, body: body.to_json, headers: headers)

      process_json_response(response, 'Failed to update TikTok webhook callback')
    end

    private

    # Tenant tự mang ứng dụng TikTok thì mã uỷ quyền do ứng dụng ấy cấp, và chỉ ứng dụng ấy
    # đổi được ra token. Không có ứng dụng riêng thì dùng ứng dụng của bản cài đặt.
    def credentials_for(account)
      app = account&.lla_platform_apps&.find_by(platform: 'tiktok')
      {
        id: app&.app_id.presence || client_id,
        secret: app&.app_secret.presence || client_secret,
        webhook_url: app&.webhook_url.presence || webhook_url
      }
    end

    def client_id
      GlobalConfigService.load('TIKTOK_APP_ID', nil)
    end

    def client_secret
      GlobalConfigService.load('TIKTOK_APP_SECRET', nil)
    end

    def process_json_response(response, error_prefix)
      unless response.success?
        Rails.logger.error "#{error_prefix}. Status: #{response.code}, Body: #{response.body}"
        raise "#{response.code}: #{response.body}"
      end

      res = JSON.parse(response.body)
      raise "#{res['code']}: #{res['message']}" if res['code'] != 0

      res
    end

    def redirect_uri
      "#{base_url}/tiktok/callback"
    end

    def webhook_url
      "#{base_url}/webhooks/tiktok"
    end

    def base_url
      ENV.fetch('FRONTEND_URL', 'http://localhost:3000')
    end

    def api_base_url
      "https://business-api.tiktok.com/open_api/#{GlobalConfigService.load('TIKTOK_API_VERSION', 'v1.3')}"
    end
  end
end
