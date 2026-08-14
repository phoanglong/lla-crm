# frozen_string_literal: true

# Người dùng thuộc nhà cung cấp SAML không có mật khẩu cục bộ để đặt lại; gửi
# email đặt lại cho họ vừa vô nghĩa vừa là một đường vòng qua IdP.
#
# Hợp đồng: spec MIT spec/enterprise/.../passwords_controller_spec.rb —
# 403 kèm `success: false` và thông điệp messages.reset_password_saml_user.
module Lla::DeviseOverrides::PasswordsController
  def create
    return render_saml_user_error if saml_user?

    super
  end

  private

  def saml_user?
    return false if params[:email].blank?

    ::User.from_email(params[:email].strip.downcase)&.provider == 'saml'
  end

  def render_saml_user_error
    render json: {
      success: false,
      errors: [I18n.t('messages.reset_password_saml_user')]
    }, status: :forbidden
  end
end
