# frozen_string_literal: true

class Captain::Conversation::MessageHistoryBuilderService
  RESOLUTION_MARKER = '<conversation_boundary status="resolved" />'
  MAX_MESSAGES = 60
  MAX_CONTENT_BYTES = 10_000
  MAX_TOTAL_BYTES = 96_000

  pattr_initialize [:conversation!]

  def perform
    remaining_bytes = MAX_TOTAL_BYTES

    bounded_messages = conversation_messages_for_context.filter_map do |message|
      message_hash = message_hash_for_context(message)
      next if message_hash.blank? || remaining_bytes <= 0

      message_hash[:agent_name] = message.additional_attributes['agent_name'].to_s.byteslice(0, 120) if agent_name_present?(message)
      message_hash[:content] = bounded_content(message_hash[:content], remaining_bytes)
      remaining_bytes -= content_bytesize(message_hash[:content])
      message_hash
    end

    bounded_messages.reverse
  end

  private

  def conversation_messages_for_context
    conversation.messages
                .where(account_id: conversation.account_id, private: false, message_type: %i[incoming outgoing activity])
                .reorder(created_at: :desc, id: :desc)
                .limit(MAX_MESSAGES)
  end

  def message_hash_for_context(message)
    return activity_message_hash(message) if message.message_type == 'activity'

    { content: prepare_multimodal_message_content(message), role: determine_role(message) }
  end

  def activity_message_hash(message)
    activity = message.content_attributes.to_h['activity'].to_h
    return unless activity['type'] == 'conversation_status_changed' && activity['status'] == 'resolved'

    { content: RESOLUTION_MARKER, role: 'assistant' }
  end

  def determine_role(message)
    message.message_type == 'incoming' ? 'user' : 'assistant'
  end

  def prepare_multimodal_message_content(message)
    Captain::OpenAiMessageBuilderService.new(message: message).generate_content
  end

  def bounded_content(content, remaining_bytes)
    budget = [MAX_CONTENT_BYTES, remaining_bytes].min
    return content.to_s.byteslice(0, budget).to_s.scrub unless content.is_a?(Array)

    content.first(6).filter_map do |part|
      next if budget <= 0

      bounded_part = bounded_content_part(part, budget)
      budget -= content_bytesize(bounded_part) if bounded_part
      bounded_part
    end
  end

  def bounded_content_part(part, limit)
    return unless part.is_a?(Hash)

    type = (part[:type] || part['type']).to_s
    return bounded_text_part(part, limit) if type == 'text'
    return bounded_image_part(part, limit) if type == 'image_url'
  end

  def bounded_text_part(part, limit)
    { type: 'text', text: (part[:text] || part['text']).to_s.byteslice(0, limit).to_s.scrub }
  end

  def bounded_image_part(part, limit)
    url = part.dig(:image_url, :url) || part.dig('image_url', 'url')
    bounded_url = url.to_s
    return unless bounded_url.start_with?('https://') && bounded_url.bytesize <= [2_048, limit].min

    { type: 'image_url', image_url: { url: bounded_url } }
  end

  def content_bytesize(content)
    return content.bytesize if content.is_a?(String)
    return 0 unless content.is_a?(Array)

    content.sum do |part|
      type = (part[:type] || part['type']).to_s
      type == 'text' ? (part[:text] || part['text']).to_s.bytesize : image_url(part).bytesize
    end
  end

  def image_url(part)
    (part.dig(:image_url, :url) || part.dig('image_url', 'url')).to_s
  end

  def agent_name_present?(message)
    message.additional_attributes&.dig('agent_name').present?
  end
end
