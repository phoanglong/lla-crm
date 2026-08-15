# frozen_string_literal: true

# Dịch vụ chat v1 của trợ lý: dựng prompt hệ thống, nạp lịch sử hội thoại
# (kể cả ảnh) rồi hỏi LLM và trả về hash theo hợp đồng ResponseSchema
# ({"response" => ..., "reasoning" => ...}).
#
# Đường v2 (agent + tool) nằm ở Captain::Assistant::AgentRunnerService.
class Captain::Llm::AssistantChatService
  include Integrations::LlmInstrumentation

  DEFAULT_TEMPERATURE = 0.5
  SPAN_NAME = 'captain.assistant.chat'
  RESPONSE_CONTEXT_LIMIT = 5

  def initialize(assistant:, conversation: nil, source: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
  end

  def generate_response(message_history: [], additional_message: nil)
    messages = normalized_history(message_history)
    messages << { role: 'user', content: additional_message } if additional_message.present?

    instrument_agent_session(instrumentation_params(messages)) do
      request_completion(messages)
    end
  end

  private

  attr_reader :assistant, :conversation, :source

  # --- LLM ---------------------------------------------------------------

  def model
    @model ||= Llm::FeatureRouter.resolve(feature: 'assistant', account: assistant.account)[:model]
  end

  def temperature
    value = assistant.config.to_h.with_indifferent_access[:temperature]
    value.presence || DEFAULT_TEMPERATURE
  end

  def build_chat
    Llm::Config.initialize!

    chat = RubyLLM.chat(model: model)
                  .with_temperature(temperature)
                  .with_params(response_format: { type: 'json_object' })
                  .with_instructions(system_prompt)
    register_callbacks(chat)
    chat
  end

  def register_callbacks(chat)
    chat.on_end_message { |message| record_generation(chat, message) }
    chat.on_tool_call { |tool_call| log_event('tool_call', tool_call.try(:name)) }
    chat.on_tool_result { |_result| log_event('tool_result', nil) }
  end

  def request_completion(messages)
    chat = build_chat
    current = messages.last
    messages[0...-1].each { |entry| chat.add_message(role: entry[:role].to_sym, content: history_content(entry)) }

    parse_response(ask(chat, current))
  end

  def ask(chat, entry)
    return chat.ask(nil) if entry.blank?

    text, attachments = split_content(entry[:content])
    return chat.ask(text, with: attachments) if attachments.any?

    chat.ask(text)
  end

  def parse_response(response)
    content = response&.content
    return { 'response' => nil } if content.blank?

    parsed = JSON.parse(content)
    parsed.is_a?(Hash) ? parsed : { 'response' => content }
  rescue JSON::ParserError => e
    Rails.logger.error("AssistantChatService parse error: #{e.message}")
    { 'response' => content }
  end

  # --- Lịch sử hội thoại -------------------------------------------------

  def normalized_history(message_history)
    Array(message_history).map { |entry| entry.to_h.symbolize_keys }
  end

  # Tin nhắn cũ có ảnh phải dựng RubyLLM::Content để LLM còn nhìn thấy ảnh.
  def history_content(entry)
    text, attachments = split_content(entry[:content])
    return text if attachments.empty?

    RubyLLM::Content.new(text, attachments)
  end

  # Trả về [văn bản, danh sách URL đính kèm] cho cả nội dung chuỗi lẫn đa phương thức.
  def split_content(content)
    return [content, []] unless content.is_a?(Array)

    text = nil
    attachments = []
    content.each do |part|
      data = part.to_h.with_indifferent_access
      case data[:type]
      when 'text' then text = data[:text]
      when 'image_url' then attachments << data.dig(:image_url, :url)
      end
    end
    [text, attachments.compact]
  end

  # --- Prompt ------------------------------------------------------------

  def system_prompt
    Captain::Llm::SystemPromptsService.assistant_response_generator(
      assistant.name,
      response_context,
      assistant.config,
      contact: contact_payload,
      custom_tools: custom_tools_metadata
    )
  end

  # Chỉ chèn thông tin liên hệ khi trợ lý được bật tính năng tương ứng.
  def contact_payload
    return if assistant.config.to_h.with_indifferent_access[:feature_contact_attributes].blank?

    contact = conversation&.contact
    return if contact.blank?

    {
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: contact.identifier,
      custom_attributes: contact.custom_attributes
    }
  end

  def custom_tools_metadata
    assistant.account.captain_custom_tools.enabled.map(&:to_tool_metadata)
  rescue StandardError => e
    Rails.logger.error("AssistantChatService custom tools error: #{e.message}")
    []
  end

  # Ngữ cảnh FAQ đã duyệt (RAG) — chỉ tra khi trợ lý bật feature_faq và đã có
  # dữ liệu, để không gọi embedding vô ích.
  def response_context
    return if assistant.config.to_h.with_indifferent_access[:feature_faq].blank?

    responses = nearest_responses
    return if responses.blank?

    responses.map { |item| "Q: #{item.question}\nA: #{item.answer}" }.join("\n\n")
  end

  def nearest_responses
    scope = assistant.responses.approved
    return if scope.none?

    embedding = Captain::Llm::EmbeddingService.new(account_id: assistant.account_id).get_embedding(last_user_text.to_s)
    scope.nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(RESPONSE_CONTEXT_LIMIT).to_a
  rescue StandardError => e
    Rails.logger.error("AssistantChatService retrieval error: #{e.message}")
    nil
  end

  def last_user_text
    entry = Array(@last_messages).reverse.find { |item| item[:role].to_s == 'user' }
    text, = split_content(entry&.[](:content))
    text
  end

  # --- Ghi vết -----------------------------------------------------------

  def instrumentation_params(messages)
    @last_messages = messages
    {
      span_name: SPAN_NAME,
      messages: messages,
      account: assistant.account,
      account_id: assistant.account_id,
      metadata: {
        assistant_id: assistant.id,
        conversation_id: conversation&.id,
        channel_type: conversation&.inbox&.channel_type,
        source: source,
        model: model
      }
    }
  end

  def record_generation(chat, message)
    return unless ChatwootApp.otel_enabled?

    span = OpenTelemetry::Trace.current_span
    generation_attributes(chat, message).each { |key, value| span.set_attribute(key, value) }
  rescue StandardError => e
    Rails.logger.error("AssistantChatService instrumentation error: #{e.message}")
  end

  def generation_attributes(chat, message)
    {
      'langfuse.observation.type' => 'generation',
      'langfuse.observation.model.name' => model,
      'langfuse.observation.input' => chat.messages.size,
      'langfuse.observation.output' => message.content.to_s,
      'langfuse.observation.usage_details.input' => message.input_tokens.to_i,
      'langfuse.observation.usage_details.output' => message.output_tokens.to_i,
      'langfuse.observation.metadata.generation_stage' => generation_stage(message)
    }
  end

  def generation_stage(message)
    message.tool_calls.present? ? 'tool_call' : 'final_response'
  end

  def log_event(event, detail)
    Rails.logger.info("[LLA AI] AssistantChatService #{event} #{detail}")
  end
end
