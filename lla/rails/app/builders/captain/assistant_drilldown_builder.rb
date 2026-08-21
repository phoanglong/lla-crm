# frozen_string_literal: true

# Returns the authorized conversations behind a Captain metric. Payloads are
# intentionally metadata-only: message content, contact identity and the latest
# message preview are omitted from this analytics endpoint.
class Captain::AssistantDrilldownBuilder
  RESOLVED_EVENT_NAMES = Captain::AssistantStatsBuilder::RESOLVED_EVENT_NAMES
  HANDOFF_EVENT_NAMES = Captain::AssistantStatsBuilder::HANDOFF_EVENT_NAMES

  SUPPORTED_METRICS = %w[
    conversations_handled auto_resolution_rate handoff_rate reopen_rate
  ].freeze
  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 25
  MAX_PAGE = 1_000
  MAX_PER_PAGE = 100
  STATEMENT_TIMEOUT = Captain::AssistantStatsBuilder::STATEMENT_TIMEOUT

  def initialize(assistant, params, conversations_scope: nil)
    @assistant = assistant
    @params = params
    @conversations_scope = (conversations_scope || assistant.account.conversations)
                           .where(account_id: assistant.account_id)
  end

  def self.supported_metric?(metric)
    SUPPORTED_METRICS.include?(metric.to_s)
  end

  def build
    with_statement_timeout do
      records = paginated_records.to_a
      { meta: meta, payload: records.map { |record| serialize(record) } }
    end
  end

  private

  attr_reader :assistant, :params, :conversations_scope

  def account
    assistant.account
  end

  def window
    @window ||= Captain::AssistantStatsWindow.new(params[:range], params[:timezone_offset])
  end

  def range
    window.current
  end

  def meta
    {
      metric: metric,
      current_page: current_page,
      per_page: per_page,
      total_count: paginated_records.total_count,
      conversation_count: paginated_records.total_count,
      range: { since: range.begin.to_i, until: range.end.to_i, end_exclusive: true }
    }
  end

  def paginated_records
    @paginated_records ||= drilldown_scope.page(current_page).per(per_page)
  end

  def drilldown_scope
    case metric
    when 'conversations_handled' then handled_conversations
    when 'auto_resolution_rate' then conversations_for(resolved_events.select(:conversation_id))
    when 'handoff_rate' then event_conversations(HANDOFF_EVENT_NAMES)
    when 'reopen_rate' then reopened_conversations
    else
      raise ArgumentError, "Unsupported assistant drilldown metric: #{metric}"
    end
  end

  def handled_messages
    account.messages.where(
      sender_type: 'Captain::Assistant',
      sender_id: assistant.id,
      conversation_id: conversations_scope.select(:id),
      created_at: range
    )
  end

  def handled_conversation_ids
    handled_messages.select(:conversation_id)
  end

  def handled_conversations
    conversations_for(handled_conversation_ids)
  end

  def event_conversations(event_names)
    ids = account.reporting_events
                 .where(name: event_names, created_at: range, conversation_id: handled_conversation_ids)
                 .select(:conversation_id)
    conversations_for(ids)
  end

  def resolved_events
    handoff_ids = account.reporting_events
                         .where(name: HANDOFF_EVENT_NAMES, created_at: range,
                                conversation_id: conversations_scope.select(:id))
                         .select(:conversation_id)
    account.reporting_events
           .where(name: RESOLVED_EVENT_NAMES, created_at: range, conversation_id: handled_conversation_ids)
           .where("NOT (name = ? AND conversation_id IN (#{handoff_ids.to_sql}))",
                  Captain::AssistantStatsBuilder::BOT_RESOLVED_EVENT_NAME)
  end

  def reopened_conversations
    ids = account.reporting_events
                 .where(name: 'conversation_opened', conversation_id: conversations_scope.select(:id))
                 .where('reporting_events.value > 0')
                 .where('reporting_events.event_end_time < ?', range.end)
                 .joins("INNER JOIN (#{resolved_events.to_sql}) resolves " \
                        'ON resolves.conversation_id = reporting_events.conversation_id ' \
                        'AND reporting_events.event_end_time >= resolves.event_end_time')
                 .select('reporting_events.conversation_id')
    conversations_for(ids)
  end

  def conversations_for(conversation_ids)
    conversations_scope
      .where(id: conversation_ids)
      .includes(:assignee, :inbox)
      .order(created_at: :desc, id: :desc)
  end

  def serialize(conversation)
    {
      record_type: 'conversation',
      conversation: {
        id: conversation.id,
        display_id: conversation.display_id,
        inbox_id: conversation.inbox_id,
        inbox_name: conversation.inbox&.name,
        assignee_id: conversation.assignee_id,
        assignee_name: conversation.assignee&.name,
        status: conversation.status,
        created_at: conversation.created_at.to_i,
        last_activity_at: conversation.last_activity_at.to_i
      },
      message: nil,
      metric_value: nil,
      occurred_at: conversation.created_at.to_i
    }
  end

  def metric
    params[:metric].to_s
  end

  def current_page
    params[:page].to_i.clamp(DEFAULT_PAGE, MAX_PAGE)
  end

  def per_page
    requested = params[:per_page].to_i
    requested = DEFAULT_PER_PAGE if requested <= 0
    [requested, MAX_PER_PAGE].min
  end

  def with_statement_timeout
    connection = account.class.connection
    previous_timeout = connection.select_value('SHOW statement_timeout')
    connection.execute("SET statement_timeout = #{connection.quote(STATEMENT_TIMEOUT)}")
    yield
  ensure
    connection&.execute("SET statement_timeout = #{connection.quote(previous_timeout)}") if previous_timeout
  end
end
