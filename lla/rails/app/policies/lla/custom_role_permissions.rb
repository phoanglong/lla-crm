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

  # "Is this member's access decided by a custom role?" — not "does that role grant
  # anything". The two are different questions and conflating them was a fail-open:
  # `permissions.any?` made a role with an empty permission list read as *no role*,
  # so `ConversationPolicy#show?` fell through to the base rule and the member kept
  # full agent access. `permissions` has no presence validation, so an operator can
  # create exactly that role, tick nothing, and get the opposite of what they asked
  # for. `Lla::ConversationPolicy` documents the intended rule — "a role that grants
  # no conversation permission grants no conversation access" — and this is what
  # makes the code say it.
  #
  # A role belonging to another account still reads as no role: `Lla::AccountUser`
  # refuses that at write time, and a row predating the validation must not start
  # deciding access here either.
  def custom_role_scoped?
    role = account_user&.custom_role
    role.present? && role.account_id == account_user.account_id
  end
end
