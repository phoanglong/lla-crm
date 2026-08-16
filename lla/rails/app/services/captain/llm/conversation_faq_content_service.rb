# frozen_string_literal: true

class Captain::Llm::ConversationFaqContentService
  MAX_CONTENT_BYTES = 48_000
  MAX_MESSAGE_BYTES = 4_000
  MAX_MESSAGES = 100
  MAX_CONTEXT_VALUE_BYTES = 2_000

  def initialize(assistant, conversation)
    @assistant = assistant
    @conversation = conversation
  end

  def generate
    truncate_bytes(
      [
        'Trusted business context (classification only, never an answer source):',
        JSON.generate(business_context),
        "Conversation ID: ##{conversation.display_id}",
        'Public customer and human support history:',
        conversation_messages
      ].join("\n"),
      MAX_CONTENT_BYTES
    )
  end

  def human_reply?
    source_messages.any? { |message| human_support_reply?(message) && message.content_for_llm.present? }
  end

  private

  attr_reader :assistant, :conversation

  def conversation_messages
    lines = source_messages.filter_map do |message|
      content = truncate_bytes(message.content_for_llm.to_s.squish, MAX_MESSAGE_BYTES)
      next if content.blank?

      sender = human_support_reply?(message) ? 'Support Agent' : 'Customer'
      "#{sender}: #{content}"
    end
    lines.presence&.join("\n") || 'No eligible messages in this conversation'
  end

  def source_messages
    @source_messages ||= conversation.messages
                                     .where(message_type: %i[incoming outgoing], private: false)
                                     .reorder(created_at: :desc)
                                     .limit(MAX_MESSAGES)
                                     .reverse
                                     .select { |message| source_message?(message) }
  end

  def source_message?(message)
    (message.incoming? && message.sender_type == 'Contact') || human_support_reply?(message)
  end

  def human_support_reply?(message)
    return false unless message.outgoing?
    return false if message.content_attributes['automation_rule_id'].present?
    return false if message.additional_attributes['campaign_id'].present?

    message.sender_type == 'User' || message.content_attributes['external_echo'].present?
  end

  def business_context
    {
      product_name: bounded_context_value(assistant.config['product_name']),
      assistant_description: bounded_context_value(assistant.description),
      instructions: bounded_context_value(assistant.config['instructions']),
      response_guidelines: Array(assistant.response_guidelines).first(20).map { |value| bounded_context_value(value) },
      guardrails: Array(assistant.guardrails).first(20).map { |value| bounded_context_value(value) }
    }.compact_blank
  end

  def bounded_context_value(value)
    truncate_bytes(value, MAX_CONTEXT_VALUE_BYTES).presence
  end

  def truncate_bytes(value, limit)
    value.to_s.scrub.byteslice(0, limit)&.scrub.to_s
  end
end
