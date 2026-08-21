# frozen_string_literal: true

# Produces the bounded, non-sensitive execution history exposed to agents.
# AgentSession records created before the LLA migration may contain a raw Array;
# current records use { messages: [...] }. Both shapes are normalized here so a
# legacy row can never bypass the current disclosure contract.
class Captain::Assistant::SessionPresenter
  MAX_MESSAGES = 20
  MAX_CONTENT_BYTES = 4_096
  MAX_LABEL_BYTES = 120
  ALLOWED_ROLES = %w[user assistant tool].freeze

  def initialize(session)
    @session = session
  end

  def run_context
    Array(raw_messages).last(MAX_MESSAGES).filter_map { |message| sanitized_message(message) }
  end

  private

  def raw_messages
    context = @session.run_context
    return context if context.is_a?(Array)
    return [] unless context.is_a?(Hash)

    context['messages'] || context[:messages] || []
  end

  def sanitized_message(message)
    return unless message.is_a?(Hash)

    attributes = message.stringify_keys
    role = bounded_string(attributes['role'], 20)
    return unless ALLOWED_ROLES.include?(role)

    {
      role: role,
      content: sanitized_content(attributes['content']),
      agent_name: bounded_string(attributes['agent_name'], MAX_LABEL_BYTES).presence,
      tool_call_id: bounded_string(attributes['tool_call_id'], MAX_LABEL_BYTES).presence
    }.compact
  end

  def sanitized_content(content)
    return bounded_string(content, MAX_CONTENT_BYTES) unless content.is_a?(Hash)

    attributes = content.stringify_keys
    {
      text: bounded_string(attributes['text'], MAX_CONTENT_BYTES),
      attachments: Array.new(Array(attributes['attachments']).length.clamp(0, 6)) { { type: 'image' } }
    }
  end

  def bounded_string(value, limit)
    value.to_s.byteslice(0, limit).to_s.scrub
  end
end
