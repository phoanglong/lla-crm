# frozen_string_literal: true

# FAQ của trợ lý: mọi thành viên tra cứu; thêm/sửa/xoá là của administrator.
class Captain::AssistantResponsePolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
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
