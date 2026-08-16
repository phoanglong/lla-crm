# frozen_string_literal: true

# Shared prompt and response normalization for the v1 routing/false-promise
# inspectors. Adapted from the authorized Enterprise implementation so the LLA
# services keep the same context bound and tolerate both Hash and JSON output.
module Captain::Llm::AssistantResponseInspectionHelpers
  MAX_CONTEXT_MESSAGES = 10

  private

  def assistant_response_inspection_prompt(message_history:, assistant_response:, response_tag:)
    <<~PROMPT
      <account_custom_instructions>
      #{@assistant.config['instructions']}
      </account_custom_instructions>

      <conversation_context>
      #{format_conversation_context(message_history)}
      </conversation_context>

      <#{response_tag}>
      #{assistant_response}
      </#{response_tag}>
    PROMPT
  end

  def format_conversation_context(messages)
    normalize_messages(messages).last(MAX_CONTEXT_MESSAGES).filter_map do |message|
      content = message[:content].to_s.strip
      next if content.blank?

      "#{role_label(message[:role])}: #{content}"
    end.join("\n")
  end

  def normalize_messages(message_history)
    Array(message_history).filter_map do |message|
      data = message.to_h.with_indifferent_access
      next if data[:role].blank?

      { role: data[:role].to_s, content: normalize_content(data[:content]) }
    end
  end

  def normalize_content(content)
    return content if content.is_a?(String)
    return content.filter_map { |part| part.to_h.with_indifferent_access[:text] if text_part?(part) }.join("\n") if content.is_a?(Array)

    content.to_s
  end

  def text_part?(part)
    part.is_a?(Hash) && part.to_h.with_indifferent_access[:type].to_s == 'text'
  end

  def role_label(role)
    return 'User' if role == 'user'
    return 'Assistant' if role == 'assistant'

    role.to_s.titleize
  end

  def parse_inspection_response(content)
    return content.stringify_keys if content.is_a?(Hash)

    JSON.parse(sanitize_json_response(content))
  rescue JSON::ParserError, TypeError
    {}
  end

  def sanitize_json_response(response)
    return response if response.nil?

    response.strip.sub(/\A```(?:\w*)\s*\n?/, '').sub(/\n?\s*```\s*\z/, '').strip
  end
end
