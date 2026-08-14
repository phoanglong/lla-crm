# frozen_string_literal: true

# Bước callback của luồng SAML.
#
# Hợp đồng lấy từ spec MIT (spec/enterprise/.../omniauth_callbacks_controller_spec.rb,
# đã chuyển sang spec/lla): MỘT request GET/POST /omniauth/saml/callback trả ngay
# redirect cuối cùng — /app/login?email=…&sso_auth_token=… (web), deep link
# chatwootapp://auth/saml?… (RelayState=mobile), hoặc
# /app/login?error=saml-authentication-failed khi bị từ chối. Vì vậy override
# `redirect_callbacks` (điểm vào của route /omniauth/:provider/callback) thay vì
# `omniauth_success` — không đi vòng 307 hai bước của devise_token_auth.
#
# Khác OAuth: người dùng phải có sẵn quyền trong tài khoản — SamlUserBuilder từ
# chối người thuộc tài khoản khác, không có nhánh đăng ký tài khoản mới.
module Lla::DeviseOverrides::OmniauthCallbacksController
  SAML_ERROR = 'saml-authentication-failed'

  def redirect_callbacks
    return super unless saml_callback?

    @resource = SamlUserBuilder.new(request.env['omniauth.auth'], saml_account_id).perform
    return redirect_to saml_error_url, allow_other_host: true unless @resource&.persisted?

    mobile_relay_state? ? sign_in_user_on_mobile : sign_in_user
  rescue SamlUserBuilder::AuthenticationFailed, ActiveRecord::RecordNotFound
    redirect_to saml_error_url, allow_other_host: true
  end

  private

  def saml_callback?
    params[:provider] == 'saml'
  end

  # account_id đi kèm bước khởi tạo /auth/saml?account_id=… và được OmniAuth giữ
  # qua phiên (env['omniauth.params']); tham số trên query string là phương án
  # dự phòng khi IdP trả thẳng về callback.
  def saml_account_id
    request.env['omniauth.params']&.dig('account_id') || params[:account_id]
  end

  def mobile_relay_state?
    (params[:RelayState] || request.env['omniauth.params']&.dig('RelayState')) == 'mobile'
  end

  def saml_error_url
    return "#{GlobalConfigService.load('MOBILE_DEEP_LINK_BASE', 'chatwootapp')}://auth/saml?error=#{SAML_ERROR}" if mobile_relay_state?

    login_page_url(error: SAML_ERROR)
  end
end
