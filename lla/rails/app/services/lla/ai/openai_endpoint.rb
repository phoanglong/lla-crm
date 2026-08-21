# frozen_string_literal: true

# Địa chỉ endpoint tương thích OpenAI của bản cài đặt, đã kiểm.
#
# Một endpoint tự đặt là nơi khoá sẽ được gửi tới, nên nó phải là HTTPS và không mang thông
# tin đăng nhập trong URL; sai hình thù thì dùng địa chỉ mặc định chứ không im lặng gửi khoá
# đi nơi khác.
class Lla::Ai::OpenaiEndpoint
  DEFAULT = 'https://api.openai.com/'

  def self.resolve
    endpoint = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value.presence || DEFAULT
    uri = URI.parse(endpoint)
    return DEFAULT unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank?

    endpoint
  rescue URI::InvalidURIError
    DEFAULT
  end
end
