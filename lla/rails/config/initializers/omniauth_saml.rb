# frozen_string_literal: true

# Đăng ký provider SAML cho Devise/OmniAuth.
#
# Cấu hình IdP thuộc về TỪNG tài khoản chứ không phải cài đặt, nên phải nạp lúc
# chạy qua pha `setup` của OmniAuth. Không tham chiếu hằng tự nạp
# (AccountSamlSettings) ở thân initializer: tệp này được `require` từ
# config/application.rb, trước khi Zeitwerk sẵn sàng — chỉ thân lambda (chạy
# theo từng request) mới được phép.
Devise.setup do |config|
  config.omniauth :saml,
                  name_identifier_format: 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress',
                  setup: lambda { |env|
                    request = ActionDispatch::Request.new(env)
                    # Pha khởi tạo có account_id trên query string; pha callback
                    # lấy lại từ tham số OmniAuth đã lưu trong phiên.
                    account_id = request.params['account_id'] ||
                                 request.session['omniauth.params'].try(:[], 'account_id')
                    settings = AccountSamlSettings.find_by(account_id: account_id)
                    next if settings.blank?

                    base_url = ENV.fetch('FRONTEND_URL', 'http://localhost:3000')
                    env['omniauth.strategy'].options.merge!(
                      idp_sso_service_url: settings.sso_url,
                      idp_cert: settings.certificate,
                      idp_entity_id: settings.idp_entity_id,
                      sp_entity_id: settings.sp_entity_id,
                      # devise_token_auth gắn middleware OmniAuth ở tiền tố
                      # /omniauth (route /auth/:provider chỉ chuyển hướng vào đây).
                      assertion_consumer_service_url: "#{base_url}/omniauth/saml/callback"
                    )
                  }
end
