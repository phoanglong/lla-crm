# frozen_string_literal: true

# Chính sách tải quyết định ai được auto-assign bao nhiêu — cấu hình vận hành
# của tài khoản, chỉ administrator được đọc và sửa.
class AgentCapacityPolicyPolicy < ApplicationPolicy
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
