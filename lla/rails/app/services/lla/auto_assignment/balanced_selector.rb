# frozen_string_literal: true

# Picks the eligible agent carrying the least open work in this inbox.
#
# Three things the upstream selector left open are closed here.
#
# **Tenancy.** The count is taken from this inbox's conversations, which are already
# account-scoped, and the candidate set is intersected with the inbox's own members.
# An agent who is not a member of this inbox cannot be counted or chosen even if a
# caller passes one in.
#
# **Ties.** `min_by` returns the first minimum in whatever order the caller happened
# to build the array, and `available_agents` comes from a query with no ORDER BY, so
# on a fresh inbox — where every agent has zero open conversations, which is exactly
# when fairness is most visible — the same agent won every time. Ties are broken by
# a per-inbox rotating cursor over the tied agents sorted by user id: deterministic
# given the cursor, and fair across calls.
#
# **Presence.** An agent with no open conversations does not appear in a GROUP BY
# over conversations at all. Counting only what the query returns and defaulting the
# rest to zero is correct, and is why the tie-break above matters.
class Lla::AutoAssignment::BalancedSelector
  pattr_initialize [:inbox!]

  CURSOR_TTL = 7.days

  # Returns a `User`, matching `AutoAssignment::RoundRobinSelector`: the caller
  # writes the result straight into `conversation.assignee` and hands it to the
  # rate limiter, both of which want the user, not the membership.
  def select_agent(available_agents)
    candidates = eligible(available_agents)
    return nil if candidates.empty?

    tied = least_loaded(candidates)
    chosen = tied.one? ? tied.first : rotate(tied.sort_by(&:user_id))
    chosen&.user
  end

  private

  def least_loaded(candidates)
    counts = open_conversation_counts(candidates.map(&:user_id))
    lowest = candidates.map { |member| counts[member.user_id].to_i }.min
    candidates.select { |member| counts[member.user_id].to_i == lowest }
  end

  # Only members of this inbox, and only once each: a caller that passes the same
  # member twice must not double its weight in the rotation.
  def eligible(available_agents)
    # Queried directly rather than through `inbox.inbox_members`: that association
    # may already be loaded and cached from earlier in the request, and a stale
    # cache here silently empties the candidate set and assigns nobody.
    member_ids = InboxMember.where(inbox_id: inbox.id).pluck(:user_id).to_set
    available_agents.select { |member| member_ids.include?(member.user_id) }.uniq(&:user_id)
  end

  def open_conversation_counts(user_ids)
    return {} if user_ids.empty?

    counts = inbox.conversations.open.where(assignee_id: user_ids).group(:assignee_id).count
    Hash.new(0).merge(counts)
  end

  # An atomic counter, so two workers breaking the same tie in the same instant get
  # different agents rather than both picking the head of the list.
  def rotate(tied)
    cursor = Redis::Alfred.incr(cursor_key)
    Redis::Alfred.expire(cursor_key, CURSOR_TTL.to_i)
    tied[(cursor.to_i - 1) % tied.length]
  rescue StandardError => e
    # Fairness is a preference; assigning the conversation is the requirement. If
    # the cursor is unavailable, fall back to a stable choice rather than failing
    # the assignment, and say so.
    Rails.logger.warn("LLA_BALANCED_TIEBREAK_UNAVAILABLE inbox=#{inbox.id} error=#{e.class.name}")
    tied.first
  end

  def cursor_key
    "lla:balanced_selector:tiebreak:#{inbox.id}"
  end
end
