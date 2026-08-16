# frozen_string_literal: true

# Computes Captain assistant metrics from an account-scoped, permission-filtered
# conversation cohort. The same scope and AssistantStatsWindow are passed to the
# drilldown builder so aggregate cards and their records cannot diverge.
# SQL cohort construction stays together so card calculations remain auditable.
# rubocop:disable Metrics/ClassLength
class Captain::AssistantStatsBuilder
  RESOLVED_EVENT_NAMES = %w[conversation_captain_inference_resolved conversation_bot_resolved].freeze
  HANDOFF_EVENT_NAMES = %w[conversation_captain_inference_handoff conversation_bot_handoff].freeze
  BOT_RESOLVED_EVENT_NAME = 'conversation_bot_resolved'
  SECONDS_SAVED_PER_REPLY = 2.minutes.to_i
  HOURS_SAVED_ASSUMPTION_VERSION = 'lla-v1'
  STATEMENT_TIMEOUT = '5s'

  attr_reader :assistant, :account

  delegate :range, :period, to: :window

  def initialize(assistant, range = Captain::AssistantStatsWindow::DEFAULT_RANGE, timezone_offset = nil,
                 suggestions_scope: nil, conversations_scope: nil)
    @assistant = assistant
    @account = assistant.account
    @window = Captain::AssistantStatsWindow.new(range, timezone_offset)
    @suggestions_scope = suggestions_scope || assistant.faq_suggestions
    @conversations_scope = (conversations_scope || account.conversations).where(account_id: account.id)
  end

  def metrics
    with_statement_timeout do
      messages = message_window_metrics
      current = window_metrics(current_range, messages.fetch(:current))
      previous = window_metrics(previous_range, messages.fetch(:previous))

      build_metrics(current, previous).merge(_meta: metrics_metadata)
    end
  end

  def faq_stats
    with_statement_timeout do
      approved = Captain::AssistantResponse.by_assistant(assistant.id).approved.count
      suggestions = suggestions_scope.where(assistant_id: assistant.id).open.reorder(nil).count
      documents = assistant.documents.count
      total = approved + suggestions

      {
        approved: approved,
        suggestions: suggestions,
        documents: documents,
        coverage: total.zero? ? 0 : (approved.to_f / total * 100).round
      }
    end
  end

  # Cache invalidation input only; no customer content is returned or persisted.
  def source_watermark
    with_statement_timeout do
      timestamps = [
        assistant.updated_at,
        handled_scope(full_span).maximum('messages.updated_at'),
        reporting_events_scope(full_span).maximum('reporting_events.updated_at'),
        Captain::AssistantResponse.by_assistant(assistant.id).maximum('captain_assistant_responses.updated_at'),
        suggestions_scope.where(assistant_id: assistant.id).maximum('captain_faq_suggestions.updated_at'),
        assistant.documents.maximum('captain_documents.updated_at')
      ]

      timestamps.compact.max&.utc&.iso8601(6)
    end
  end

  private

  attr_reader :window, :suggestions_scope, :conversations_scope

  def current_range
    window.current
  end

  def previous_range
    window.previous
  end

  def build_metrics(current, previous)
    {
      conversations_handled: pack(current[:handled], previous[:handled], :percent),
      auto_resolution_rate: pack(current[:auto_resolution], previous[:auto_resolution], :point),
      handoff_rate: pack(current[:handoff], previous[:handoff], :point),
      hours_saved: pack(current[:hours_saved], previous[:hours_saved], :percent),
      reopen_rate: pack(current[:reopen], previous[:reopen], :point),
      conversation_depth: pack(current[:depth], previous[:depth], :absolute)
    }
  end

  def metrics_metadata
    {
      window: {
        since: current_range.begin.to_i,
        until: current_range.end.to_i,
        end_exclusive: true,
        timezone_offset: window.timezone_offset
      },
      hours_saved: {
        estimated: true,
        seconds_per_reply: SECONDS_SAVED_PER_REPLY,
        assumption_version: HOURS_SAVED_ASSUMPTION_VERSION
      }
    }
  end

  def window_metrics(range, message_counts)
    handled = message_counts[:handled]
    public_count = message_counts[:public_count]
    depth_conversations = message_counts[:depth_conversations]
    resolution = resolution_counts(range)

    {
      handled: handled,
      auto_resolution: rate(resolution[:resolved], handled),
      handoff: rate(resolution[:handoff], handled),
      hours_saved: (public_count * SECONDS_SAVED_PER_REPLY / 3600.0).round,
      reopen: reopen_rate(range, resolution[:resolved]),
      depth: depth_conversations.zero? ? 0 : (public_count.to_f / depth_conversations).round(1)
    }
  end

  def message_window_metrics
    current, previous = [current_range, previous_range].map { |range| message_aggregates(range) }
    row = handled_scope(full_span).reorder(nil).pick(
      current[:handled], previous[:handled], current[:public_count], previous[:public_count],
      current[:depth_conversations], previous[:depth_conversations]
    )

    {
      current: { handled: row[0], public_count: row[2], depth_conversations: row[4] },
      previous: { handled: row[1], public_count: row[3], depth_conversations: row[5] }
    }
  end

  def message_aggregates(range)
    messages = Message.arel_table
    window = created_at_window(messages, range)
    public_window = window.and(
      messages[:message_type].eq(Message.message_types[:outgoing]).and(messages[:private].eq(false))
    )

    {
      handled: filtered_count(messages[:conversation_id], window, distinct: true),
      public_count: filtered_count(messages[:id], public_window),
      depth_conversations: filtered_count(messages[:conversation_id], public_window, distinct: true)
    }
  end

  def resolution_counts(range)
    reporting_events = ReportingEvent.arel_table
    row = reporting_events_scope(range)
          .where(name: RESOLVED_EVENT_NAMES + HANDOFF_EVENT_NAMES,
                 conversation_id: handled_scope(range).select(:conversation_id))
          .reorder(nil)
          .pick(
            filtered_count(reporting_events[:conversation_id], resolved_event_predicate(reporting_events, range),
                           distinct: true),
            filtered_count(reporting_events[:conversation_id], reporting_events[:name].in(HANDOFF_EVENT_NAMES),
                           distinct: true)
          )
    { resolved: row[0], handoff: row[1] }
  end

  def resolved_event_predicate(reporting_events, range)
    bot_resolved_after_handoff = reporting_events[:name].eq(BOT_RESOLVED_EVENT_NAME).and(
      reporting_events[:conversation_id].in(handoff_conversation_ids(range).arel)
    )

    reporting_events[:name].in(RESOLVED_EVENT_NAMES).and(Arel::Nodes::Not.new(bot_resolved_after_handoff))
  end

  def handoff_conversation_ids(range)
    reporting_events_scope(range).where(name: HANDOFF_EVENT_NAMES).select(:conversation_id)
  end

  def handled_scope(range)
    account.messages.where(
      sender_type: 'Captain::Assistant',
      sender_id: assistant.id,
      conversation_id: conversations_scope.select(:id),
      created_at: range
    )
  end

  def reporting_events_scope(range)
    account.reporting_events.where(created_at: range, conversation_id: conversations_scope.select(:id))
  end

  def full_span
    [current_range.begin, previous_range.begin].min...current_range.end
  end

  def created_at_window(table, range)
    table[:created_at].gteq(range.begin).and(table[:created_at].lt(range.end))
  end

  def filtered_count(attribute, predicate, distinct: false)
    attribute.count(distinct).filter(predicate)
  end

  def reopen_rate(range, resolved_count)
    return 0 if resolved_count.zero?

    resolved_scope = reporting_events_scope(range)
                     .where(name: RESOLVED_EVENT_NAMES,
                            conversation_id: handled_scope(range).select(:conversation_id))
                     .where(resolved_event_predicate(ReportingEvent.arel_table, range))
    reopened = account.reporting_events
                      .where(name: 'conversation_opened', conversation_id: conversations_scope.select(:id))
                      .where('reporting_events.value > 0')
                      .where('reporting_events.event_end_time < ?', range.end)
                      .joins("INNER JOIN (#{resolved_scope.to_sql}) resolves " \
                             'ON resolves.conversation_id = reporting_events.conversation_id ' \
                             'AND reporting_events.event_end_time >= resolves.event_end_time')
                      .distinct.count('reporting_events.conversation_id')
    rate(reopened, resolved_count)
  end

  def with_statement_timeout
    connection = account.class.connection
    previous_timeout = connection.select_value('SHOW statement_timeout')
    connection.execute("SET statement_timeout = #{connection.quote(STATEMENT_TIMEOUT)}")
    yield
  ensure
    connection&.execute("SET statement_timeout = #{connection.quote(previous_timeout)}") if previous_timeout
  end

  def rate(numerator, denominator)
    return 0 if denominator.zero?

    (numerator.to_f / denominator * 100).round(1)
  end

  def pack(current, previous, mode)
    { current: current, previous: previous, trend: trend(current, previous, mode) }
  end

  def trend(current, previous, mode)
    case mode
    when :percent
      previous.zero? ? 0 : ((current - previous).to_f / previous * 100).round(1)
    else
      (current - previous).round(1)
    end
  end
end
# rubocop:enable Metrics/ClassLength
