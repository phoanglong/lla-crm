# frozen_string_literal: true

module Captain::Assistant::TracePayloadHelper
  private

  def enrich_context_with_trace_payload!(context, message_history, message_to_process)
    context[:captain_v2_trace_input] = trace_summary(message_history)
    context[:captain_v2_trace_current_input] = trace_summary([{ role: 'user', content: message_to_process }])
  end

  def trace_summary(messages)
    normalized = Array(messages)
    {
      message_count: normalized.length,
      roles: normalized.filter_map { |message| message[:role].to_s.presence }.tally,
      content_bytes: normalized.sum { |message| trace_content_bytes(message[:content]) },
      multimodal: normalized.any? { |message| multimodal_content?(message[:content]) }
    }.to_json
  end

  def safe_trace_summary(value)
    parsed = JSON.parse(value.to_s)
    return unless parsed.is_a?(Hash)

    parsed.slice('message_count', 'roles', 'content_bytes', 'multimodal').to_json
  rescue JSON::ParserError
    nil
  end

  def trace_content_bytes(content)
    case content
    when RubyLLM::Content then content.text.to_s.bytesize
    when String then content.bytesize
    else content.to_json.bytesize
    end
  rescue StandardError
    0
  end

  def multimodal_content?(content)
    content.is_a?(RubyLLM::Content) || (content.is_a?(Array) && content.any? { |part| (part[:type] || part['type']) == 'image_url' })
  end
end
