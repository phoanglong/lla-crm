# frozen_string_literal: true

# Tài liệu tri thức: mọi thành viên đọc; nạp/sync/xoá là của administrator.
class Captain::DocumentPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def create?
    @account_user.administrator?
  end

  def sync?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end
end
