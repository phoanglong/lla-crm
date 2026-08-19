# frozen_string_literal: true

# Custom-role conversation access, applied on top of the community rule rather than
# instead of it: a custom role can only ever narrow what inbox and team membership
# already allow.
#
# Three grants, in decreasing breadth:
#   conversation_manage               — every conversation the base rule allows
#   conversation_unassigned_manage    — unassigned conversations, and their own
#   conversation_participating_manage — their own, and ones they participate in
#
# A role with none of the three is refused rather than falling through to the base
# rule: a role that grants no conversation permission grants no conversation access.
module Lla::ConversationPolicy
  include Lla::CustomRolePermissions

  def show?
    return false unless super
    return true unless custom_role_scoped?

    permissions = custom_role_permissions
    return true if permissions.include?('conversation_manage')
    return true if permits_unassigned_manage?(permissions)

    permits_participating?(permissions)
  end

  private

  def permits_unassigned_manage?(permissions)
    return false unless permissions.include?('conversation_unassigned_manage')

    record.assignee_id.nil? || assigned_to_user?
  end

  def permits_participating?(permissions)
    return false unless permissions.include?('conversation_participating_manage')

    assigned_to_user? || participant?
  end
end
