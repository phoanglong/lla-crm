# frozen_string_literal: true

module Captain::Conversation::MessageBuilder
  MAX_HISTORY_MESSAGES = 50
  MAX_HISTORY_BYTES = 80_000
  MAX_OUTGOING_MESSAGE_LENGTH = 10_000

  private

  def collect_previous_messages
    messages = @conversation.messages
                            .where(
                              account_id: @conversation.account_id,
                              message_type: %i[incoming outgoing],
                              private: false
                            )
                            .reorder(id: :desc)
                            .limit(MAX_HISTORY_MESSAGES)

    total_bytes = 0
    collected = []
    messages.each do |message|
      content = prepare_multimodal_message_content(message)
      content_bytes = content.to_json.bytesize
      break if total_bytes + content_bytes > MAX_HISTORY_BYTES

      total_bytes += content_bytes
      collected << message_history_entry(message, content)
    end
    collected.reverse
  end

  def message_history_entry(message, content)
    {
      content: content,
      role: message.incoming? ? 'user' : 'assistant'
    }.tap do |entry|
      agent_name = message.additional_attributes&.dig('agent_name').presence
      entry[:agent_name] = agent_name if agent_name
    end
  end

  def prepare_multimodal_message_content(message)
    Captain::OpenAiMessageBuilderService.new(message: message).generate_content
  end

  def create_messages
    content = @response['response']
    validate_message_content!(content)
    create_outgoing_message(content, agent_name: @response['agent_name'])
  end

  def validate_message_content!(content)
    raise ArgumentError, 'Message content cannot be blank' if content.blank?
    raise ArgumentError, 'Message content exceeds maximum length' if content.to_s.length > MAX_OUTGOING_MESSAGE_LENGTH
  end

  def create_outgoing_message(message_content, agent_name: nil, preserve_waiting_since: false)
    additional_attrs = {}
    additional_attrs[:agent_name] = agent_name if agent_name.present?
    additional_attrs[:captain_source_message_id] = @starting_message_id if @starting_message_id.present?

    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: message_content,
      additional_attributes: additional_attrs,
      preserve_waiting_since: preserve_waiting_since
    )
  end
end
