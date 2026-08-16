# frozen_string_literal: true

require 'agents'
require 'agents/instrumentation'
require 'timeout'

class Captain::Assistant::AgentRunnerService
  include Integrations::LlmInstrumentationConstants
  include Captain::Assistant::RunnerCallbacksHelper
  include Captain::Assistant::RunnerContentHelper
  include Captain::Assistant::TracePayloadHelper
  include Captain::Assistant::RunnerStateHelper

  MAX_TURNS = 10
  MAX_RUNTIME_SECONDS = 45
  MAX_TOOL_CALLS = 20
  MAX_HISTORY_MESSAGES = 60
  MAX_TEXT_BYTES = 10_000
  MAX_REASONING_BYTES = 4_000

  class InvalidRuntimeContextError < StandardError; end
  class ToolBudgetExceededError < StandardError; end

  attr_reader :last_run_result

  def initialize(assistant:, conversation: nil, callbacks: {}, source: nil)
    @assistant = assistant
    @conversation = conversation
    @callbacks = callbacks.slice(:on_agent_thinking, :on_tool_start, :on_tool_complete, :on_agent_handoff)
    @source = source.to_s.byteslice(0, 64)
    @handoff_tool_called = false
  end

  def generate_response(message_history: [])
    validate_runtime_context!
    message_to_process, context = run_payload(Array(message_history).last(MAX_HISTORY_MESSAGES))
    @last_run_result = Timeout.timeout(MAX_RUNTIME_SECONDS) do
      runner.run(message_to_process, context: context, max_turns: MAX_TURNS)
    end

    process_agent_result(@last_run_result)
  rescue StandardError => e
    capture_sanitized_exception(e)
    log_runtime_error(e)
    error_response
  end

  private

  def validate_runtime_context!
    raise InvalidRuntimeContextError unless valid_assistant_context?
    return if @conversation.nil?

    raise InvalidRuntimeContextError unless valid_conversation_context?
  end

  def valid_assistant_context?
    @assistant&.persisted? && @assistant.account_id.present?
  end

  def valid_conversation_context?
    @conversation.persisted? && @conversation.account_id == @assistant.account_id &&
      @conversation.inbox&.account_id == @assistant.account_id &&
      CaptainInbox.exists?(inbox_id: @conversation.inbox_id, captain_assistant_id: @assistant.id)
  end

  def process_agent_result(result)
    output = result.output
    response = output.is_a?(Hash) ? output.with_indifferent_access : { response: output.to_s, reasoning: 'Processed by agent' }

    payload = {
      'response' => response[:response].to_s.byteslice(0, MAX_TEXT_BYTES).to_s.scrub,
      'agent_name' => result.context&.dig(:current_agent).to_s.byteslice(0, 120).presence,
      'handoff_tool_called' => result.context&.dig(:captain_v2_handoff_tool_called) || false
    }
    reasoning = response[:reasoning].to_s.byteslice(0, MAX_REASONING_BYTES).to_s.scrub.presence
    payload['reasoning'] = reasoning if reasoning
    payload
  end

  def error_response
    {
      'response' => 'conversation_handoff',
      'reasoning' => 'Agent runtime unavailable',
      'handoff_tool_called' => @handoff_tool_called
    }
  end

  def capture_sanitized_exception(error)
    sanitized = StandardError.new("Captain V2 runtime failure: #{error.class.name}")
    ChatwootExceptionTracker.new(sanitized, account: @conversation&.account || @assistant&.account).capture_exception
  rescue StandardError
    nil
  end

  def log_runtime_error(error)
    Rails.logger.error(
      "LLA Captain V2 runner failed account_id=#{@assistant&.account_id} " \
      "conversation_id=#{@conversation&.id} error=#{error.class.name}"
    )
  end

  def build_and_wire_agents
    assistant_agent = @assistant.agent
    scenario_agents = @assistant.scenarios.enabled.map(&:agent)

    assistant_agent.register_handoffs(*scenario_agents) if scenario_agents.any?
    scenario_agents.each { |scenario_agent| scenario_agent.register_handoffs(assistant_agent) }

    [assistant_agent] + scenario_agents
  end

  def install_instrumentation(configured_runner)
    return unless ChatwootApp.otel_enabled?

    Agents::Instrumentation.install(
      configured_runner,
      tracer: OpentelemetryConfig.tracer,
      trace_name: 'llm.captain_v2',
      span_attributes: { ATTR_LANGFUSE_TAGS => ['captain_v2'].to_json },
      attribute_provider: Captain::Assistant::InstrumentationAttributeProvider.new(self)
    )
    register_trace_input_callback(configured_runner)
  end

  def dynamic_trace_attributes(context_wrapper)
    state = context_wrapper&.context&.dig(:state) || {}
    conversation = state[:conversation] || {}
    trace_summary = safe_trace_summary(context_wrapper&.context&.dig(:captain_v2_trace_input))

    {
      ATTR_LANGFUSE_USER_ID => state[:account_id],
      format(ATTR_LANGFUSE_METADATA, 'assistant_id') => state[:assistant_id],
      format(ATTR_LANGFUSE_METADATA, 'conversation_id') => conversation[:id],
      format(ATTR_LANGFUSE_METADATA, 'channel_type') => state[:channel_type],
      format(ATTR_LANGFUSE_METADATA, 'source') => state[:source],
      ATTR_LANGFUSE_TRACE_INPUT => trace_summary,
      ATTR_LANGFUSE_OBSERVATION_INPUT => trace_summary
    }.compact.transform_values(&:to_s)
  end

  def add_usage_metadata_callback(configured_runner)
    handoff_tool_name = Captain::Tools::HandoffTool.new(@assistant).name

    configured_runner.on_tool_complete do |tool_name, _tool_result, context_wrapper|
      track_tool_usage(tool_name, handoff_tool_name, context_wrapper)
    end

    if ChatwootApp.otel_enabled?
      configured_runner.on_run_complete do |_agent_name, _result, context_wrapper|
        write_credits_used_metadata(context_wrapper)
      end
    end
    configured_runner
  end

  def track_tool_usage(tool_name, handoff_tool_name, context_wrapper)
    context = context_wrapper&.context
    return unless context

    context[:captain_v2_tool_calls] = context.fetch(:captain_v2_tool_calls, 0) + 1
    raise ToolBudgetExceededError if context[:captain_v2_tool_calls] > MAX_TOOL_CALLS

    track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
  end

  def track_handoff_usage(tool_name, handoff_tool_name, context_wrapper)
    return unless context_wrapper&.context && tool_name.to_s == handoff_tool_name

    context_wrapper.context[:captain_v2_handoff_tool_called] = true
    @handoff_tool_called = true
  end

  def write_credits_used_metadata(context_wrapper)
    root_span = context_wrapper&.context&.dig(:__otel_tracing, :root_span)
    return unless root_span

    root_span.set_attribute(format(ATTR_LANGFUSE_METADATA, 'credit_used'), @handoff_tool_called ? 'false' : 'true')
  end

  def runner
    @runner ||= begin
      configured_runner = Agents::Runner.with_agents(*build_and_wire_agents)
      configured_runner = add_usage_metadata_callback(configured_runner)
      configured_runner = add_callbacks_to_runner(configured_runner) if @callbacks.any?
      install_instrumentation(configured_runner)
      configured_runner
    end
  end

  def run_payload(message_history)
    message_to_process = extract_last_user_message(message_history)
    context = build_context(message_history_without_last_user_message(message_history))
    enrich_context_with_trace_payload!(context, message_history, message_to_process)
    [message_to_process, context]
  end
end
