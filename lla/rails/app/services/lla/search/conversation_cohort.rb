# frozen_string_literal: true

# The set of conversations one member is allowed to see, expressed as a relation so
# it can be applied inside a query instead of after one.
#
# `ConversationPolicy` decides this for a single record on `show?`. Search never
# asked it: it filtered by assigned inbox only, so a member holding
# `conversation_participating_manage` — a role that exists precisely to stop them
# reading their colleagues' conversations — could read any conversation in any inbox
# they belonged to, and any message inside it, simply by searching for it. The rule
# has to be the same rule in both places, which is why this returns a relation the
# search can join against rather than a second implementation of the same idea.
class Lla::Search::ConversationCohort
  MANAGE_ALL = 'conversation_manage'
  UNASSIGNED = 'conversation_unassigned_manage'
  PARTICIPATING = 'conversation_participating_manage'

  pattr_initialize [:account!, :user!, :account_user, :inbox_ids!]

  # A relation over conversations, already scoped to the account and the inboxes the
  # caller may read.
  def relation
    base = account.conversations
    base = base.where(inbox_id: inbox_ids) unless inbox_ids.nil?
    return base unless custom_role_scoped?

    permissions = custom_role_permissions
    return base if permissions.include?(MANAGE_ALL)
    return unassigned_scope(base) if permissions.include?(UNASSIGNED)
    return participating_scope(base) if permissions.include?(PARTICIPATING)

    # A custom role that grants no conversation permission grants no conversations.
    base.none
  end

  def restricted?
    custom_role_scoped? && custom_role_permissions.exclude?(MANAGE_ALL)
  end

  private

  def unassigned_scope(base)
    base.where(assignee_id: [nil, user.id])
  end

  def participating_scope(base)
    base.where(assignee_id: user.id)
        .or(base.where(id: participating_conversation_ids))
  end

  def participating_conversation_ids
    ConversationParticipant.where(user_id: user.id).select(:conversation_id)
  end

  def custom_role_scoped?
    custom_role.present?
  end

  # A role belonging to another account grants nothing, matching the write-time
  # validation on `Lla::AccountUser`.
  def custom_role
    return @custom_role if defined?(@custom_role)

    role = account_user&.custom_role
    @custom_role = role.present? && role.account_id == account.id ? role : nil
  end

  def custom_role_permissions
    @custom_role_permissions ||= custom_role&.permissions.to_a.map(&:to_s)
  end
end
