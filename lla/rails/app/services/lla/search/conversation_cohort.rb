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

  # A relation over conversations, already scoped to the account and to what the
  # caller may read.
  def relation
    base = base_scope
    return base unless custom_role_scoped?

    permissions = custom_role_permissions
    return base if permissions.include?(MANAGE_ALL)

    grants = []
    grants << unassigned_scope(base) if permissions.include?(UNASSIGNED)
    grants << participating_scope(base) if permissions.include?(PARTICIPATING)

    # A custom role that grants no conversation permission grants no conversations.
    return base.none if grants.empty?

    # The grants are additive, exactly as `ConversationPolicy#show?` applies them:
    # each `return true if …` there is a union, not a branch. Reading them as an
    # elsif ladder made a member holding both `unassigned_manage` and
    # `participating_manage` lose the participating half — a conversation they could
    # open by URL was invisible to search.
    grants.reduce { |left, right| left.or(right) }
  end

  def restricted?
    custom_role_scoped? && custom_role_permissions.exclude?(MANAGE_ALL)
  end

  private

  # `ConversationPolicy` reaches a conversation through `inbox_access? ||
  # team_access?`. Filtering on inbox alone made a conversation that is only
  # reachable through team membership unsearchable, while remaining openable.
  def base_scope
    scope = account.conversations
    return scope if inbox_ids.nil?

    return scope.where(inbox_id: inbox_ids) if team_ids.empty?

    scope.where(inbox_id: inbox_ids).or(scope.where(team_id: team_ids))
  end

  def team_ids
    @team_ids ||= user.teams.where(account_id: account.id).pluck(:id)
  end

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
