# frozen_string_literal: true

# One reader for custom-role permissions, shared by every LLA policy.
#
# The enterprise policies each wrote `@account_user.custom_role&.permissions&.include?('x')`
# inline. Four copies of the same expression drift, and none of them said what
# happens when the role belongs to a different account — which `belongs_to` alone
# never prevented. `Lla::AccountUser` now refuses that at write time; this refuses to
# honour it at read time as well, so a row that predates the validation cannot grant
# anything.
module Lla::CustomRolePermissions
  private

  def custom_role_permissions
    role = account_user&.custom_role
    return [] if role.blank?
    return [] unless role.account_id == account_user.account_id

    role.permissions.to_a.map(&:to_s)
  end

  def custom_role_permits?(permission)
    custom_role_permissions.include?(permission)
  end

  def custom_role_scoped?
    account_user&.custom_role_id.present? && custom_role_permissions.any?
  end
end
