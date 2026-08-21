# frozen_string_literal: true

# The OpenSearch half of `Lla::SearchService`, kept separate because it is a
# different failure model: an optional external index that can be stale, absent, or
# wrong, sitting in front of a database that is none of those things.
module Lla::Search::AdvancedSearch
  private

  # OpenSearch, when configured. The index is not the authority on who may read a
  # document: `account_id` and `inbox_id` are values written at index time, and a
  # document can outlive the authorization that produced it. So the index narrows,
  # and the database decides — the returned ids are re-read through the cohort
  # relation, and anything that no longer passes is dropped.
  def advanced_search
    return Message.none.page(params[:page]).per(PER_PAGE) unless query_searchable?

    results = Message.search(
      search_query,
      fields: %w[content attachments.transcribed_text content_attributes.email.subject],
      where: advanced_search_conditions,
      order: { created_at: :desc },
      page: params[:page] || 1,
      per_page: PER_PAGE
    )
    authorize_advanced_results(results)
  end

  def advanced_search_conditions
    conditions = { account_id: current_account.id }
    conditions[:inbox_id] = accessable_inbox_ids unless should_skip_inbox_filtering?
    apply_advanced_from_filter(conditions)
    apply_advanced_time_filter(conditions)
    apply_advanced_inbox_filter(conditions)
    conditions
  end

  def apply_advanced_from_filter(conditions)
    sender_type, sender_id = parse_from_param(params[:from])
    return unless sender_type && sender_id

    conditions[:sender_type] = sender_type
    conditions[:sender_id] = sender_id
  end

  def apply_advanced_time_filter(conditions)
    time_conditions = {}
    time_conditions[:gte] = advanced_search_since
    time_conditions[:lte] = advanced_search_until if params[:until].present?
    conditions[:created_at] = time_conditions if time_conditions.any?
  end

  def advanced_search_since
    max_lookback = Limits::MESSAGE_SEARCH_TIME_RANGE_LIMIT_DAYS.days.ago
    return max_lookback if params[:since].blank?

    [Time.zone.at(params[:since].to_i), max_lookback].max
  end

  def advanced_search_until
    [Time.zone.at(params[:until].to_i), 90.days.from_now].min
  end

  def apply_advanced_inbox_filter(conditions)
    return if params[:inbox_id].blank?

    inbox_id = params[:inbox_id].to_i
    return if inbox_id.zero?
    return unless validate_inbox_access(inbox_id)

    conditions[:inbox_id] = inbox_id
  end

  # A stale or tampered index document must not become an API result.
  def authorize_advanced_results(results)
    return results unless conversation_cohort.restricted?

    permitted = conversation_cohort.relation
                                   .where(id: results.filter_map(&:conversation_id).uniq)
                                   .pluck(:id).to_set
    results.reject { |message| permitted.exclude?(message.conversation_id) }
  end
end
