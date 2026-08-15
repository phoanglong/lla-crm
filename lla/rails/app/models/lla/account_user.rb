# frozen_string_literal: true

# Mở rộng AccountUser cho năng lực LLA. Prepend qua
# `AccountUser.prepend_mod_with('AccountUser')` trong app/models/account_user.rb (MIT).
module Lla::AccountUser
  extend ActiveSupport::Concern

  prepended do
    belongs_to :custom_role, optional: true
    belongs_to :agent_capacity_policy, optional: true
  end

  # Quyền hiệu lực của thành viên. Khi có vai trò tuỳ chỉnh thì trả về đúng danh
  # sách quyền của vai trò đó; ngược lại giữ nguyên hành vi CE (['administrator']
  # hoặc ['agent']) — frontend dựa vào cả hai dạng, xem
  # app/javascript/dashboard/helper/permissionsHelper.js.
  def permissions
    return super if custom_role_id.blank?

    custom_role&.permissions.presence || super
  end

  # Đúng khi đây là agent bị giới hạn bởi vai trò tuỳ chỉnh. Administrator không
  # bao giờ bị lọc theo permission.
  def custom_role_agent?
    agent? && custom_role_id.present?
  end
end
