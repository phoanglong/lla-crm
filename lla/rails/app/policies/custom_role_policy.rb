# frozen_string_literal: true

# Vai trò tuỳ chỉnh là cấu hình phân quyền của tài khoản: chỉ administrator được
# đọc và sửa. Agent — kể cả agent đang mang một custom role — không được xem.
class CustomRolePolicy < ApplicationPolicy
  def index?
    @account_user.administrator?
  end

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
