# frozen_string_literal: true

# LLA ownership of message and conversation search.
#
# Four things are corrected here, all of them reachable from an ordinary search box.
#
# **A blank query returned everything.** `ILIKE '%%'` matches every row, so an empty
# `q` paged through the account's entire message history. It now returns nothing:
# searching for nothing is not a request for everything.
#
# **`%` and `_` were not escaped.** A user typing `%` got the same full scan, and a
# user searching for a literal underscore got the wrong results.
#
# **`to_tsquery` received raw user input.** `to_tsquery('a & ')`, `to_tsquery(':')`
# and anything containing `!`, `|` or an unbalanced parenthesis raise
# `PG::SyntaxError` — a 500 from a search box. `websearch_to_tsquery` parses user
# text as user text and never raises.
#
# **Custom-role limits did not apply to search.** The result set was filtered by
# assigned inbox only, so a member restricted to their own conversations could read
# any conversation in their inboxes, and any message in it, by searching for it. The
# cohort is now the same one `ConversationPolicy` applies to a single record.
module Lla::SearchService
  include Lla::Search::AdvancedSearch

  # One character, not two. A conversation's display id is often a single digit,
  # and searching for it is the most common thing anyone does with this box — a
  # two-character floor silently returned nothing for conversation 7. What the
  # floor is actually for is the empty query, which used to become `ILIKE '%%'`
  # and page through the account's entire history.
  MIN_QUERY_LENGTH = 1
  MAX_QUERY_LENGTH = 200
  PER_PAGE = 15

  private

  def search_query
    @search_query ||= params[:q].to_s.strip.slice(0, MAX_QUERY_LENGTH).to_s
  end

  def query_searchable?
    search_query.length >= MIN_QUERY_LENGTH
  end

  # `%` and `_` are LIKE wildcards; `\` escapes them. Escaped for the default
  # `ESCAPE '\'` behaviour of PostgreSQL's LIKE.
  def like_pattern
    "%#{search_query.gsub('\\', '\\\\\\\\').gsub('%', '\\%').gsub('_', '\\_')}%"
  end

  def conversation_cohort
    @conversation_cohort ||= Lla::Search::ConversationCohort.new(
      account: current_account,
      user: current_user,
      account_user: account_user,
      inbox_ids: should_skip_inbox_filtering? ? nil : accessable_inbox_ids
    )
  end

  def filter_conversations
    return @conversations = Conversation.none.page(params[:page]).per(PER_PAGE) unless query_searchable?

    conversations_query = conversation_cohort.relation
                                             .joins('INNER JOIN contacts ON conversations.contact_id = contacts.id')
                                             .where(
                                               'cast(conversations.display_id as text) ILIKE :search ' \
                                               'OR contacts.name ILIKE :search OR contacts.email ILIKE :search ' \
                                               'OR contacts.phone_number ILIKE :search OR contacts.identifier ILIKE :search',
                                               search: like_pattern
                                             )

    if current_account.feature_enabled?('advanced_search')
      conversations_query = apply_time_filter(conversations_query, 'conversations.last_activity_at')
    end

    @conversations = conversations_query.order('conversations.created_at DESC')
                                        .page(params[:page]).per(PER_PAGE)
  end

  def filter_messages
    return @messages = Message.none.page(params[:page]).per(PER_PAGE) unless query_searchable?

    super
  end

  def filter_contacts
    return @contacts = Contact.none.page(params[:page]).per(PER_PAGE) unless query_searchable?

    contacts_query = current_account.contacts.where(
      'name ILIKE :search OR email ILIKE :search OR phone_number ILIKE :search OR identifier ILIKE :search',
      search: like_pattern
    )
    contacts_query = apply_time_filter(contacts_query, 'last_activity_at') if current_account.feature_enabled?('advanced_search')

    @contacts = contacts_query.resolved_contacts(use_crm_v2: current_account.feature_enabled?('crm_v2'))
                              .order_on_last_activity_at('desc').page(params[:page]).per(PER_PAGE)
  end

  # The message cohort is the conversation cohort: a message is readable exactly
  # when the conversation carrying it is.
  def message_base_query
    query = super
    return query unless conversation_cohort.restricted?

    query.where(conversation_id: conversation_cohort.relation.select(:id))
  end

  def filter_messages_with_like
    base_query = apply_message_filters(message_base_query)
    base_query.where('messages.content ILIKE :search', search: like_pattern)
              .reorder('created_at DESC').page(params[:page]).per(PER_PAGE)
  end

  # `websearch_to_tsquery` accepts what a person types — quoted phrases, `or`, `-` —
  # and never raises on punctuation. `to_tsquery` raised `PG::SyntaxError` on a
  # trailing `&`, on `:`, and on an unbalanced bracket.
  def filter_messages_with_gin
    base_query = apply_message_filters(message_base_query)
    base_query.where('content @@ websearch_to_tsquery(?)', search_query)
              .reorder('created_at DESC').page(params[:page]).per(PER_PAGE)
  end
end
