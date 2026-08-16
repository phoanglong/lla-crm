# frozen_string_literal: true

# Trợ lý AI: mọi thành viên account xem/thử được; tạo/sửa/xoá và quản lý
# inbox gắn kèm là việc của administrator.
class Captain::AssistantPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def playground?
    true
  end

  def faq_stats?
    true
  end

  def summary?
    true
  end

  def metrics?
    true
  end

  def drilldown?
    @account_user.administrator?
  end

  def tools?
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

  def sync?
    @account_user.administrator?
  end

  def approve?
    update?
  end

  def dismiss?
    update?
  end
end
