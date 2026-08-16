# frozen_string_literal: true

# Internal, non-customer-facing completion evaluation for inactive Captain
# conversations. It always uses the installation credential and never consumes
# response quota.
class Captain::ConversationCompletionService < Captain::BaseTaskService
  RESPONSE_SCHEMA = Captain::ConversationCompletionSchema
  MAX_TRANSCRIPT_BYTES = 64_000
  MAX_MESSAGES = 100
  MAX_REASON_BYTES = 500

  pattr_initialize [:account!, :conversation_display_id!]

  def perform
    return default_incomplete_response('Conversation not found') unless valid_conversation?

    content = format_evaluation_input
    return default_incomplete_response('No public messages found') if content.blank?

    response = make_api_call(
      model: InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || GPT_MODEL,
      messages: [
        { role: 'system', content: completion_prompt },
        { role: 'user', content: content }
      ],
      schema: RESPONSE_SCHEMA
    )

    return default_incomplete_response('Evaluation unavailable') if response[:error].present?

    parse_response(response[:message])
  end

  private

  def valid_conversation?
    conversation.present? && conversation.account_id == account.id
  end

  def completion_prompt
    Rails.root.join('lla/rails/lib/captain/prompts/conversation_completion.liquid').read
  end

  def format_evaluation_input
    messages = conversation_message_records
    return if messages.blank?

    [
      "Conversation status: #{conversation.status}",
      "Conversation transcript:\n#{format_messages_as_string(messages)}"
    ].join("\n\n")
  end

  def conversation_message_records
    selected = []
    bytes = 0

    conversation.messages
                .where(message_type: %i[incoming outgoing], private: false)
                .reorder(id: :desc)
                .limit(MAX_MESSAGES * 2)
                .each do |message|
      content = message.content_for_llm.to_s.scrub.strip
      next if content.blank?

      content = content.byteslice(0, MAX_TRANSCRIPT_BYTES)&.scrub
      break if bytes + content.bytesize > MAX_TRANSCRIPT_BYTES

      selected.prepend(message: message, content: content)
      bytes += content.bytesize
      break if selected.size >= MAX_MESSAGES
    end

    selected
  end

  def format_messages_as_string(messages)
    messages.map do |message_context|
      "#{message_sender_label(message_context[:message])}: #{message_context[:content]}"
    end.join("\n")
  end

  def message_sender_label(message)
    return 'Customer' if message.incoming?
    return 'LLA Assistant' if message.sender_type == 'Captain::Assistant'
    return 'Automation' if message.sender_type == 'AgentBot'

    'Human Agent'
  end

  def parse_response(message)
    return default_incomplete_response('Invalid evaluation response') unless message.is_a?(Hash)
    return default_incomplete_response('Invalid completion value') unless [true, false].include?(message['complete'])

    {
      complete: message['complete'],
      reason: safe_reason(message['reason'])
    }
  end

  def safe_reason(reason)
    value = reason.to_s.scrub.squish.byteslice(0, MAX_REASON_BYTES)&.scrub
    value.presence || 'No reason provided'
  end

  def default_incomplete_response(reason)
    { complete: false, reason: reason }
  end

  # BaseTaskService's generic span stores message content. Completion input may
  # contain customer data, so this service deliberately disables content spans.
  def instrument_llm_call(_params)
    yield
  end

  def llm_credential
    @llm_credential ||= system_llm_credential
  end

  def counts_toward_usage?
    false
  end

  def event_name
    'captain.conversation_completion'
  end

  def build_follow_up_context?
    false
  end
end
