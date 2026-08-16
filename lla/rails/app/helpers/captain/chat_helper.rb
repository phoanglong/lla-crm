# frozen_string_literal: true

# rubocop:disable Rails/HelperInstanceVariable, Metrics/ModuleLength -- service mixin, not a view helper

require 'timeout'

module Captain::ChatHelper
  include Captain::ChatResponseHelper
  include Captain::ChatGenerationRecorder
  include Integrations::LlmInstrumentationConstants

  REQUEST_TIMEOUT = 45.seconds
  TOOL_CALL_LIMIT = 12
  ToolBudgetExceededError = Class.new(StandardError)

  def request_chat_completion
    log_chat_completion_request
    llm_chat = build_chat

    add_messages_to_chat(llm_chat)
    with_safe_agent_session do
      text, attachments = Captain::OpenAiMessageBuilderService.extract_text_and_attachments(conversation_messages.last[:content])
      Timeout.timeout(REQUEST_TIMEOUT) do
        response = attachments.any? ? llm_chat.ask(text, with: attachments) : llm_chat.ask(text)
        build_response(response)
      end
    end
  rescue StandardError => e
    Rails.logger.error(
      "LLA chat completion failed service=#{self.class.name} account_id=#{resolved_account_id} " \
      "assistant_id=#{@assistant&.id} error=#{e.class.name}"
    )
    raise
  end

  private

  def build_chat
    llm_chat = chat(model: @model, temperature: temperature).with_params(response_format: { type: 'json_object' })
    llm_chat = setup_tools(llm_chat)
    llm_chat = setup_system_instructions(llm_chat)
    setup_event_handlers(llm_chat)
  end

  def setup_tools(llm_chat)
    Array(@tools).first(TOOL_CALL_LIMIT).each { |tool| llm_chat = llm_chat.with_tool(tool) }
    llm_chat
  end

  def setup_system_instructions(llm_chat)
    instructions = @messages.filter_map { |item| item[:content] if item[:role].to_s == 'system' }.join("\n\n")
    llm_chat.with_instructions(instructions)
  end

  def setup_event_handlers(llm_chat)
    llm_chat.on_end_message { |message| record_llm_generation(llm_chat, message) }
    llm_chat.on_tool_call { |tool_call| handle_tool_call(tool_call) }
    llm_chat.on_tool_result { |result| handle_tool_result(result) }
    llm_chat
  end

  def handle_tool_call(tool_call)
    @tool_call_count = @tool_call_count.to_i + 1
    raise ToolBudgetExceededError, 'Copilot tool-call budget exceeded' if @tool_call_count > TOOL_CALL_LIMIT

    persist_thinking_message(tool_call)
    start_safe_tool_span(tool_call)
    (@pending_tool_calls ||= []).push(tool_call)
  end

  def handle_tool_result(result)
    finish_safe_tool_span(result)
    persist_tool_completion
  end

  def add_messages_to_chat(llm_chat)
    conversation_messages[0...-1].each do |message|
      text, attachments = Captain::OpenAiMessageBuilderService.extract_text_and_attachments(message[:content])
      content = attachments.any? ? RubyLLM::Content.new(text, attachments) : text
      llm_chat.add_message(role: message[:role].to_sym, content: content)
    end
  end

  def conversation_messages
    @messages.reject { |item| item[:role].to_s == 'system' }
  end

  def temperature
    configured = @assistant&.config&.[]('temperature').presence&.to_f
    (configured || 0.5).clamp(0.0, 2.0)
  end

  def with_safe_agent_session
    return yield unless ChatwootApp.otel_enabled?

    span = tracer.start_span("llm.captain.#{feature_name}")
    apply_safe_session_attributes(span)
    result = yield
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, { output_bytes: result.to_json.bytesize }.to_json)
    result
  ensure
    finish_span_safely(span)
  end

  def apply_safe_session_attributes(span)
    span.set_attribute(ATTR_LANGFUSE_USER_ID, resolved_account_id.to_s)
    span.set_attribute(ATTR_LANGFUSE_SESSION_ID, @run_id.to_s)
    span.set_attribute(ATTR_LANGFUSE_TAGS, [feature_name])
    span.set_attribute(
      ATTR_LANGFUSE_OBSERVATION_INPUT,
      { message_count: @messages.length, input_bytes: @messages.sum { |item| item[:content].to_s.bytesize } }.to_json
    )
  rescue StandardError => e
    Rails.logger.warn("LLA chat session telemetry failed service=#{self.class.name} error=#{e.class.name}")
  end

  def start_safe_tool_span(tool_call)
    return unless ChatwootApp.otel_enabled?

    span = tracer.start_span("llm.tool.#{safe_tool_name(tool_call)}")
    summary = safe_tool_input_summary(tool_call)
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_TYPE, 'tool')
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_INPUT, summary.to_json)
    (@pending_tool_spans ||= []).push(span)
  rescue StandardError => e
    Rails.logger.warn("LLA tool telemetry start failed service=#{self.class.name} error=#{e.class.name}")
  end

  def safe_tool_input_summary(tool_call)
    arguments = tool_call.respond_to?(:arguments) ? tool_call.arguments : nil
    { argument_count: arguments.is_a?(Hash) ? arguments.length : 0, input_bytes: arguments.to_json.bytesize }
  end

  def safe_tool_name(tool_call)
    candidate = tool_call.respond_to?(:name) ? tool_call.name.to_s : ''
    allowed_name = Array(@tools).map { |tool| tool.class.name.to_s }.find { |name| name == candidate }
    allowed_name.presence || 'unknown'
  end

  def finish_span_safely(span)
    span&.finish
  rescue StandardError
    nil
  end

  def finish_safe_tool_span(result)
    span = @pending_tool_spans&.pop
    return unless span

    span.set_attribute(
      ATTR_LANGFUSE_OBSERVATION_OUTPUT,
      { output_type: result.class.name, output_bytes: result.to_s.bytesize }.to_json
    )
  rescue StandardError => e
    Rails.logger.warn("LLA tool telemetry finish failed service=#{self.class.name} error=#{e.class.name}")
  ensure
    finish_span_safely(span)
  end

  def log_chat_completion_request
    Rails.logger.info(
      "LLA chat completion started service=#{self.class.name} account_id=#{resolved_account_id} " \
      "assistant_id=#{@assistant&.id} messages=#{@messages.length} tools=#{Array(@tools).length}"
    )
  end

  def resolved_account_id
    @account&.id || @assistant&.account_id
  end

  def feature_name
    raise NotImplementedError, "#{self.class.name} must implement #feature_name"
  end
end
# rubocop:enable Rails/HelperInstanceVariable, Metrics/ModuleLength
