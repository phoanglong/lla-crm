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
    report_viewer?
  end

  def summary?
    report_viewer?
  end

  def metrics?
    report_viewer?
  end

  def drilldown?
    report_viewer?
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

  private

  def report_viewer?
    @account_user.administrator? || @account_user.custom_role&.permissions&.include?('report_manage')
  end
end
