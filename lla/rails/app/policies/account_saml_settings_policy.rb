# frozen_string_literal: true

# Cấu hình SAML quyết định cách toàn bộ thành viên đăng nhập vào tài khoản, nên
# chỉ administrator được đọc và sửa.
class AccountSamlSettingsPolicy < ApplicationPolicy
  def show?
    @account_user.administrator?
  end

  def create?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end
end
