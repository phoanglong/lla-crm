# frozen_string_literal: true

# Ghi sự kiện đăng nhập / đăng xuất vào nhật ký kiểm toán.
#
# Hợp đồng lấy từ spec MIT
# spec/.../devise_overrides/session_controller_spec.rb: đăng nhập thành công tạo
# đúng một bản ghi `sign_in` với auditable = user và associated = Account; sai
# mật khẩu thì không tạo bản ghi nào.
module Lla::DeviseOverrides::SessionsController
  # Người dùng thuộc nhà cung cấp SAML không được đăng nhập bằng mật khẩu; chỉ
  # luồng SSO (sso_auth_token) mới hợp lệ. Kiểm soát này đi cùng Wave B2 vì tệp
  # override tương ứng bên enterprise/ bị gỡ trong cùng commit — phần còn lại của
  # SAML (cấu hình, omniauth) thuộc Wave B3.
  def create
    return render_saml_login_error if saml_password_login?

    super
  end

  def render_create_success
    record_session_audit('sign_in', @resource)
    super
  end

  def destroy
    signed_in_user = current_user
    super
    record_session_audit('sign_out', signed_in_user)
  end

  private

  def saml_password_login?
    return false if params[:email].blank?
    return false if params[:sso_auth_token].present?

    ::User.from_email(params[:email].strip.downcase)&.provider == 'saml'
  end

  def render_saml_login_error
    render_error(:unauthorized, I18n.t('messages.login_saml_user'))
  end

  # Một bản ghi cho mỗi tài khoản mà người dùng thuộc về: nhật ký của tài khoản A
  # phải trả lời được "ai đã đăng nhập vào A", không phụ thuộc tài khoản khác.
  def record_session_audit(action, user)
    return if user.blank?

    user.accounts.each do |account|
      Audited.audit_class.create!(
        auditable: user,
        associated: account,
        user: user,
        username: user.name,
        action: action,
        remote_address: request.remote_ip,
        request_uuid: request.uuid
      )
    end
  end
end
