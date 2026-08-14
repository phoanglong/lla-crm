# frozen_string_literal: true

# Điểm vào luồng đăng nhập SAML từ giao diện: người dùng nhập email công việc,
# hệ thống tìm tài khoản đang bật SAML của họ rồi chuyển sang IdP.
#
# Hợp đồng lấy từ nguồn MIT:
# - config/routes.rb — `post 'auth/saml_login', to: 'auth#saml_login'`
# - app/javascript/v3/views/login/Saml.vue — biểu mẫu POST với `email` và `target`
# - spec/enterprise/controllers/api/v1/auth_controller_spec.rb — đặc tả chạy được
class Api::V1::AuthController < ApplicationController
  SAML_ERROR = 'saml-authentication-failed'

  def saml_login
    return head :bad_request if params[:email].blank?

    account = saml_enabled_account
    return redirect_to error_url, allow_other_host: true if account.blank?

    redirect_to initiation_url(account), allow_other_host: true
  end

  private

  def mobile?
    params[:target] == 'mobile'
  end

  # Không tiết lộ email nào tồn tại: mọi trường hợp không đăng nhập SAML được đều
  # trả về cùng một lỗi.
  def saml_enabled_account
    user = User.from_email(params[:email])
    return if user.blank?

    user.accounts.detect do |account|
      account.feature_enabled?('saml') && AccountSamlSettings.exists?(account_id: account.id)
    end
  end

  def initiation_url(account)
    url = "/auth/saml?account_id=#{account.id}"
    # RelayState được IdP trả lại nguyên văn ở bước callback, nhờ đó biết phải
    # đưa người dùng về ứng dụng di động hay trình duyệt.
    url += '&RelayState=mobile' if mobile?
    url
  end

  def error_url
    return "#{mobile_deep_link_base}://auth/saml?error=#{SAML_ERROR}" if mobile?

    "#{ENV.fetch('FRONTEND_URL', nil)}/app/login/sso?error=#{SAML_ERROR}"
  end

  def mobile_deep_link_base
    GlobalConfigService.load('MOBILE_DEEP_LINK_BASE', 'chatwootapp')
  end
end
