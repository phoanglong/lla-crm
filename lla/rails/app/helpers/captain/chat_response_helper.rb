# frozen_string_literal: true

# rubocop:disable Rails/HelperInstanceVariable -- service mixin, not a view helper

module Captain::ChatResponseHelper
  include Integrations::LlmInstrumentationConstants

  MAX_RESPONSE_BYTES = 32_768
  MAX_REASONING_BYTES = 8_192

  private

  def build_response(response)
    content = response.content.to_s
    raise ArgumentError, 'LLM response is too large' if content.bytesize > MAX_RESPONSE_BYTES

    parsed = normalize_response(parse_json_response(content))
    apply_credit_usage_metadata(parsed)
    persist_message(parsed, 'assistant')
    parsed
  end

  def parse_json_response(content)
    JSON.parse(sanitize_json_response(content))
  rescue JSON::ParserError
    { 'content' => content.to_s.byteslice(0, MAX_RESPONSE_BYTES).to_s.scrub }
  end

  def normalize_response(parsed)
    parsed = {} unless parsed.is_a?(Hash)
    normalized = {
      'content' => bounded_response_value(parsed['content'], MAX_RESPONSE_BYTES),
      'reasoning' => bounded_response_value(parsed['reasoning'], MAX_REASONING_BYTES),
      'reply_suggestion' => ActiveModel::Type::Boolean.new.cast(parsed['reply_suggestion'])
    }
    normalized.compact
  end

  def bounded_response_value(value, limit)
    return if value.nil?

    value.to_s.byteslice(0, limit).to_s.scrub
  end

  def apply_credit_usage_metadata(parsed_response)
    return unless feature_name == 'assistant' && !@assistant.account.feature_enabled?('captain_integration_v2')
    return unless ChatwootApp.otel_enabled?

    response = parsed_response['content']
    OpenTelemetry::Trace.current_span.set_attribute(
      format(ATTR_LANGFUSE_METADATA, 'credit_used'),
      response.present?.to_s
    )
  rescue StandardError => e
    Rails.logger.warn("LLA credit telemetry failed assistant_id=#{@assistant&.id} error=#{e.class.name}")
  end

  def persist_thinking_message(tool_call)
    return if @copilot_thread.blank?

    tool_name = safe_tool_name(tool_call)
    persist_message({ 'content' => "Using #{tool_name}", 'function_name' => tool_name }, 'assistant_thinking')
  end

  def persist_tool_completion
    return if @copilot_thread.blank?

    tool_call = @pending_tool_calls&.pop
    return unless tool_call

    tool_name = safe_tool_name(tool_call)
    persist_message({ 'content' => "Completed #{tool_name}", 'function_name' => tool_name }, 'assistant_thinking')
  end
end
# rubocop:enable Rails/HelperInstanceVariable
