# frozen_string_literal: true

# Agent cần đọc được danh sách SLA (hiển thị trên hội thoại); chỉ administrator
# được tạo/sửa/xoá.
class SlaPolicyPolicy < ApplicationPolicy
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
