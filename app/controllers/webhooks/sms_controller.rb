class Webhooks::SmsController < ActionController::API
  # Bandwidth xác thực callback bằng HTTP Basic (RFC 7235): thông tin đăng nhập đặt trong
  # application hoặc lúc tạo subscription, và Bandwidth chỉ gửi kèm sau khi nhận được 401 có
  # `WWW-Authenticate`. Trước đây endpoint này nhận mọi POST, nên bất kỳ ai biết số điện thoại
  # đều bơm được tin giả vào hộp thư của tenant.
  #
  # Chỉ bắt buộc khi tenant đã khai thông tin đăng nhập: Bandwidth cho phép để trống, và ép
  # buộc ngược lại sẽ cắt luồng tin của những tenant đang chạy mà không báo trước.
  before_action :authenticate_callback!

  def process_payload
    Webhooks::SmsEventsJob.perform_later(params['_json']&.first&.to_unsafe_hash)
    head :ok
  end

  private

  def authenticate_callback!
    credentials = callback_credentials
    return if credentials.blank?

    given = basic_auth_pair
    return if given.present? && secure_match?(given, credentials)

    response.headers['WWW-Authenticate'] = 'Basic realm=""'
    head :unauthorized
  end

  # Header thiếu hoặc không giải mã được base64 thì coi như không có thông tin đăng nhập.
  def basic_auth_pair
    ActionController::HttpAuthentication::Basic.user_name_and_password(request)
  rescue StandardError
    nil
  end

  def secure_match?(given, expected)
    ActiveSupport::SecurityUtils.secure_compare(given[0].to_s, expected[:username]) &
      ActiveSupport::SecurityUtils.secure_compare(given[1].to_s, expected[:password])
  end

  def callback_credentials
    channel = Channel::Sms.find_by(phone_number: params[:phone_number])
    return if channel.blank?

    config = channel.provider_config.to_h.with_indifferent_access
    username = config[:callback_username].presence
    password = config[:callback_password].presence
    return if username.blank? || password.blank?

    { username: username, password: password }
  end
end
