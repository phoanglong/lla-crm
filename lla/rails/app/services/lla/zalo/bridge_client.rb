# frozen_string_literal: true

# Máy khách HTTP tới admin API của cầu Zalo.
#
# Cầu là dịch vụ Node riêng giữ App Secret và token OA của từng tenant. Token quản
# trị của cầu **không bao giờ** được đi ra trình duyệt — mọi lệnh gọi đi qua đây, ở
# phía máy chủ. Địa chỉ cầu do người vận hành đặt trong Super Admin, không do người
# dùng gửi lên, nên không có bề mặt SSRF nào ở đây.
class Lla::Zalo::BridgeClient
  TIMEOUT = 8
  CONNECTION_ID_PATTERN = /\A[a-z0-9]{4,32}\z/

  class Error < StandardError; end
  class NotConfigured < Error; end
  class Unauthorized < Error; end
  class NotFound < Error; end
  class InvalidCredentials < Error; end
  class Unavailable < Error; end

  def self.base_url
    (GlobalConfig.get_value('ZALO_BRIDGE_URL').presence || ENV.fetch('ZALO_BRIDGE_URL', '')).to_s.chomp('/')
  end

  def self.admin_token
    (GlobalConfig.get_value('ZALO_BRIDGE_ADMIN_TOKEN').presence || ENV.fetch('ZALO_BRIDGE_ADMIN_TOKEN', '')).to_s
  end

  def self.configured?
    base_url.present? && admin_token.present?
  end

  def self.create_connection(name:, app_id:, app_secret:, oa_id: nil)
    request(:post, '/api/connections',
            body: { name: name, app_id: app_id, app_secret: app_secret, oa_id: oa_id }.compact)
  end

  # Hộp thư chỉ tồn tại sau khi CRM tạo xong, nên việc gắn là bước thứ hai.
  # `cw_url` là địa chỉ của chính bản cài này: một cầu phục vụ được nhiều bản cài
  # (UAT và production), và tin phải quay về đúng nơi hộp thư đang sống.
  def self.bind_connection(connection_id, account_id:, inbox_id:, webhook_secret:)
    request(:patch, connection_path(connection_id),
            body: { cw_url: ENV.fetch('FRONTEND_URL', '').to_s.chomp('/'),
                    cw_account_id: account_id.to_s, cw_inbox_id: inbox_id.to_s,
                    cw_webhook_secret: webhook_secret })
  end

  def self.connection(connection_id)
    request(:get, connection_path(connection_id))
  end

  def self.connection_path(connection_id)
    raise NotFound unless CONNECTION_ID_PATTERN.match?(connection_id.to_s)

    "/api/connections/#{connection_id}"
  end
  private_class_method :connection_path

  def self.request(verb, path, body: nil)
    raise NotConfigured unless configured?

    response = HTTParty.public_send(
      verb, "#{base_url}#{path}",
      headers: headers, body: body&.to_json, timeout: TIMEOUT, follow_redirects: false
    )
    interpret(response)
  rescue Timeout::Error, Errno::ETIMEDOUT, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET,
         OpenSSL::SSL::SSLError, HTTParty::Error
    raise Unavailable
  end
  private_class_method :request

  def self.headers
    { 'Content-Type' => 'application/json', 'Accept' => 'application/json',
      'X-Bridge-Admin-Token' => admin_token }
  end
  private_class_method :headers

  # Thân phản hồi của cầu không chứa secret nào (xem `connPublicView`), nên trả
  # thẳng cho người gọi được; còn lỗi thì quy về kiểu, không bê nguyên văn ra ngoài.
  ERROR_FOR_STATUS = {
    401 => Unauthorized, 403 => Unauthorized, 404 => NotFound,
    422 => InvalidCredentials, 503 => NotConfigured
  }.freeze

  def self.interpret(response)
    status = response.code.to_i
    return JSON.parse(response.body.presence || '{}') if status.between?(200, 299)

    raise ERROR_FOR_STATUS.fetch(status, Unavailable)
  rescue JSON::ParserError
    raise Unavailable
  end
  private_class_method :interpret
end
