# frozen_string_literal: true

module Captain::Assistant::RunnerContentHelper
  private

  def build_context(message_history)
    {
      session_id: runtime_session_id,
      conversation_history: message_history.filter_map { |message| context_message(message) },
      state: build_state
    }
  end

  def context_message(message)
    role = message[:role].to_s
    return unless %w[user assistant tool].include?(role)

    {
      role: role.to_sym,
      content: bounded_content(message[:content]),
      agent_name: message[:agent_name].to_s.byteslice(0, 120).presence
    }
  end

  def runtime_session_id
    return "#{@assistant.account_id}_#{@conversation.display_id}" if @conversation

    "#{@assistant.account_id}_playground_#{SecureRandom.uuid}"
  end

  def extract_last_user_message(message_history)
    last_user_message = message_history.reverse.find { |message| message[:role].to_s == 'user' }
    return '' if last_user_message.blank?

    content = bounded_content(last_user_message[:content])
    return extract_text_from_content(content) unless content.is_a?(Array)

    text, attachments = Captain::OpenAiMessageBuilderService.extract_text_and_attachments(content)
    attachments.present? ? RubyLLM::Content.new(text, attachments) : text
  end

  def message_history_without_last_user_message(message_history)
    last_user_index = message_history.rindex { |message| message[:role].to_s == 'user' }
    return message_history if last_user_index.nil?

    message_history.reject.with_index { |_message, index| index == last_user_index }
  end

  def bounded_content(content)
    case content
    when Array then content.first(6).filter_map { |part| bounded_content_part(part) }
    when Hash then bounded_text(extract_text_from_content(content))
    else bounded_text(content)
    end
  end

  def bounded_content_part(part)
    return unless part.is_a?(Hash)

    type = (part[:type] || part['type']).to_s
    return bounded_text_part(part) if type == 'text'
    return bounded_image_part(part) if type == 'image_url'
  end

  def bounded_text_part(part)
    { type: 'text', text: bounded_text(part[:text] || part['text']) }
  end

  def bounded_image_part(part)
    url = part.dig(:image_url, :url) || part.dig('image_url', 'url')
    bounded_url = url.to_s
    return unless bounded_url.start_with?('https://') && bounded_url.bytesize <= 2_048

    { type: 'image_url', image_url: { url: bounded_url } }
  end

  def bounded_text(value)
    value.to_s.byteslice(0, Captain::Assistant::AgentRunnerService::MAX_TEXT_BYTES).to_s.scrub
  end

  def extract_text_from_content(content)
    return content[:response] || content['response'] || content.to_s if content.is_a?(Hash)
    return content unless content.is_a?(Array)

    content.filter_map { |part| text_from_content_part(part) }.join(' ')
  end

  def text_from_content_part(part)
    return unless part.is_a?(Hash) && (part[:type] || part['type']).to_s == 'text'

    part[:text] || part['text']
  end
end
