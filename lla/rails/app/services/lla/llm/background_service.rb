# frozen_string_literal: true

# Privacy-safe foundation for background LLM tasks that process CRM records.
# Unlike interactive instrumentation, this class never records prompts or model
# responses. Traces contain identifiers and byte counts only.
class Lla::Llm::BackgroundService
  include Integrations::LlmInstrumentation

  DEFAULT_TEMPERATURE = 0.1
  MAX_CONTEXT_BYTES = 32_000
  MAX_MESSAGE_BYTES = 4_000
  MAX_MESSAGES = 50

  private

  attr_reader :account, :assistant, :contact, :conversation

  def assign_memory_runtime_context(assistant_id:, conversation_id:, account_id:)
    account = Account.active.find_by(id: account_id)
    assistant = Captain::Assistant.find_by(id: assistant_id, account_id: account_id)
    conversation = Conversation.includes(inbox: :captain_assistant).find_by(id: conversation_id, account_id: account_id)
    contact = conversation&.contact
    return false unless valid_memory_runtime_context?(account, assistant, conversation, contact)

    @account = account
    @assistant = assistant
    @conversation = conversation
    @contact = contact
    true
  end

  def valid_memory_runtime_context?(account, assistant, conversation, contact)
    return false unless [account, assistant, conversation, contact].all?(&:present?)
    return false unless conversation.resolved?

    contact.account_id == account.id && conversation.inbox.account_id == account.id &&
      conversation.inbox.captain_assistant&.id == assistant.id
  end

  def request_json(system_prompt:, content:, span_name:, metadata: {}, feature: 'assistant')
    Llm::Config.initialize!
    request_model = model_for(feature)
    response = instrument_private_call(
      span_name: span_name,
      model: request_model,
      temperature: DEFAULT_TEMPERATURE,
      account_id: account.id,
      conversation_id: conversation.display_id,
      feature_name: metadata.delete(:feature_name),
      metadata: metadata.merge(input_bytes: content.bytesize)
    ) do
      RubyLLM.chat(model: request_model)
             .with_temperature(DEFAULT_TEMPERATURE)
             .with_params(response_format: { type: 'json_object' })
             .with_instructions(system_prompt)
             .ask(content)
    end

    parse_json_object(response&.content)
  end

  def instrument_private_call(params)
    return yield unless ChatwootApp.otel_enabled?

    instrument_with_span(params[:span_name], params) do |_span, track_result|
      result = yield
      track_result.call(result)
      result
    end
  end

  def model_for(feature)
    @models ||= {}
    @models[feature] ||= Llm::FeatureRouter.resolve(feature: feature, account: account)[:model]
  end

  def parse_json_object(content)
    return {} if content.blank?
    return content.stringify_keys if content.is_a?(Hash)

    sanitized = content.to_s.strip.sub(/\A```(?:\w*)\s*\n?/, '').sub(/\n?\s*```\s*\z/, '').strip
    parsed = JSON.parse(sanitized)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def memory_context(include_notes: false)
    sections = ["Contact ID: ##{contact.id}"]
    sections << existing_attributes_section
    sections << existing_notes_section if include_notes
    sections << transcript_section
    truncate_bytes(sections.compact.join("\n\n"), MAX_CONTEXT_BYTES)
  end

  def existing_attributes_section
    values = account.custom_attribute_definitions.contact_attribute.filter_map do |definition|
      value = contact.custom_attributes.to_h[definition.attribute_key]
      "#{definition.attribute_display_name} (#{definition.attribute_key}): #{value}" if value.present?
    end
    return if values.empty?

    "Existing contact attributes:\n#{values.join("\n")}"
  end

  def existing_notes_section
    notes = contact.notes.where(account_id: account.id).latest.limit(10).pluck(:content).reverse
    return if notes.empty?

    "Existing durable notes:\n#{notes.map { |note| "- #{truncate_bytes(note, 1_000)}" }.join("\n")}"
  end

  def transcript_section
    messages = conversation.messages
                           .where(private: false, sender_type: %w[Contact User])
                           .reorder(created_at: :desc)
                           .limit(MAX_MESSAGES)
                           .reverse
    lines = messages.filter_map do |message|
      content = truncate_bytes(message.content_for_llm.to_s.squish, MAX_MESSAGE_BYTES)
      next if content.blank?

      role = message.sender_type == 'Contact' ? 'Customer' : 'Human agent'
      "#{role}: #{content}"
    end
    "Public customer and human-agent transcript:\n#{lines.join("\n")}"
  end

  def truncate_bytes(value, limit)
    value.to_s.scrub.byteslice(0, limit)&.scrub.to_s
  end

  def capture_failure(error, operation)
    redacted_error = StandardError.new("#{operation} failed: #{error.class.name}")
    ChatwootExceptionTracker.new(redacted_error, account: account).capture_exception
    Rails.logger.warn(
      "LLA Captain background LLM failed operation=#{operation} account_id=#{account.id} " \
      "conversation_id=#{conversation.id} error=#{error.class.name}"
    )
  end
end
