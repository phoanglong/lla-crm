# frozen_string_literal: true

# Soát câu trả lời dự kiến trước khi gửi: có hứa hẹn ngoài ngữ cảnh đã biết
# không. Luôn dùng model kiểm định cố định, không theo override của account.
class Captain::Llm::AssistantFalsePromiseService
  DETECTOR_MODEL = Llm::FeatureRouter::CAPTAIN_V2_ASSISTANT_MODEL
  TEMPERATURE = 0.0

  include Integrations::LlmInstrumentation
  include Captain::Llm::AssistantResponseInspectionHelpers

  def initialize(assistant:, conversation:)
    raise ArgumentError, 'assistant and conversation must belong to the same account' if assistant.account_id != conversation.account_id

    @assistant = assistant
    @conversation = conversation
    Llm::Config.initialize!
  end

  def detect(message_history:, assistant_response:)
    user_prompt = assistant_response_inspection_prompt(
      message_history: message_history,
      assistant_response: assistant_response,
      response_tag: 'assistant_response_to_check'
    )
    response = instrument_llm_call(instrumentation_params(user_prompt)) { chat.ask(user_prompt) }

    normalize_response(parse_inspection_response(response.content), response.content)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: @conversation.account).capture_exception
    Rails.logger.warn("[LLA AI][AssistantFalsePromise] conversation=#{@conversation.display_id} error=#{e.class.name}")
    { 'decision' => nil, 'reason' => nil, 'error' => e.message, 'model' => DETECTOR_MODEL }
  end

  private

  def chat
    RubyLLM.chat(model: DETECTOR_MODEL)
           .with_temperature(TEMPERATURE)
           .with_schema(Captain::AssistantFalsePromiseSchema)
           .with_instructions(Captain::Llm::SystemPromptsService.assistant_false_promise_detector)
  end

  def normalize_response(parsed, raw_content)
    decision = parsed['decision'].to_s
    reason = parsed['reason'].to_s
    return invalid_response(raw_content) unless Captain::AssistantFalsePromiseSchema::DECISIONS.include?(decision)
    return invalid_response(raw_content) unless Captain::AssistantFalsePromiseSchema::REASONS.include?(reason)

    { 'decision' => decision, 'reason' => reason, 'raw_response' => raw_content, 'model' => DETECTOR_MODEL }
  end

  def invalid_response(raw_content)
    {
      'decision' => nil,
      'reason' => nil,
      'raw_response' => raw_content,
      'error' => 'invalid_false_promise_response',
      'model' => DETECTOR_MODEL
    }
  end

  def instrumentation_params(user_prompt)
    {
      span_name: 'llm.captain.assistant_false_promise_detector',
      model: DETECTOR_MODEL,
      temperature: TEMPERATURE,
      account_id: @conversation.account_id,
      conversation_id: @conversation.display_id,
      feature_name: 'assistant_false_promise_detector',
      messages: [
        { role: 'system', content: Captain::Llm::SystemPromptsService.assistant_false_promise_detector },
        { role: 'user', content: user_prompt }
      ],
      metadata: {
        assistant_id: @assistant.id,
        channel_type: @conversation.inbox&.channel_type,
        source: 'v1_response_builder'
      }
    }
  end
end
