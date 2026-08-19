# frozen_string_literal: true

# Mở rộng AccountUser cho năng lực LLA. Prepend qua
# `AccountUser.prepend_mod_with('AccountUser')` trong app/models/account_user.rb (MIT).
module Lla::AccountUser
  extend ActiveSupport::Concern

  prepended do
    belongs_to :custom_role, optional: true
    belongs_to :agent_capacity_policy, optional: true
    validate :custom_role_belongs_to_account
    validate :agent_capacity_policy_belongs_to_account
  end

  # Quyền hiệu lực của thành viên. Khi có vai trò tuỳ chỉnh thì trả về danh sách
  # quyền của vai trò đó cùng marker `custom_role`; ngược lại giữ nguyên hành vi
  # CE (['administrator'] hoặc ['agent']) — frontend/router dựa vào cả hai dạng, xem
  # app/javascript/dashboard/helper/permissionsHelper.js.
  def permissions
    return super if custom_role.blank?

    (custom_role.permissions.map(&:to_s) + ['custom_role']).uniq
  end

  # Đúng khi đây là agent bị giới hạn bởi vai trò tuỳ chỉnh. Administrator không
  # bao giờ bị lọc theo permission.
  def custom_role_agent?
    agent? && custom_role_id.present?
  end

  private

  def custom_role_belongs_to_account
    return if custom_role_id.blank?
    return if custom_role&.account_id == account_id

    errors.add(:custom_role, 'must belong to the same account as the account user')
  end

  # Cùng lý do với custom_role: `belongs_to ... optional: true` không ràng buộc tenant,
  # nên một membership của tài khoản A có thể trỏ sang chính sách sức chứa của tài
  # khoản B và im lặng đổi hành vi auto-assignment của A.
  def agent_capacity_policy_belongs_to_account
    return if agent_capacity_policy_id.blank?
    return if agent_capacity_policy&.account_id == account_id

    errors.add(:agent_capacity_policy, 'must belong to the same account as the account user')
  end
end
