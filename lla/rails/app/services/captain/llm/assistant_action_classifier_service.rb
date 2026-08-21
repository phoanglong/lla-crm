# frozen_string_literal: true

# Phân loại hành động kế tiếp cho câu trả lời dự kiến của trợ lý
# (reply/handoff/…) bằng LLM với schema cứng.
class Captain::Llm::AssistantActionClassifierService
  include Integrations::LlmInstrumentation
  include Captain::Llm::AssistantResponseInspectionHelpers

  TEMPERATURE = 0.0

  def initialize(assistant:, conversation:)
    raise ArgumentError, 'assistant and conversation must belong to the same account' if assistant.account_id != conversation.account_id

    @assistant = assistant
    @conversation = conversation
    Llm::Config.initialize!
  end

  def classify(message_history:, assistant_response:)
    user_prompt = assistant_response_inspection_prompt(
      message_history: message_history,
      assistant_response: assistant_response,
      response_tag: 'assistant_response_to_classify'
    )
    response = instrument_llm_call(instrumentation_params(user_prompt)) { chat.ask(user_prompt) }

    normalize_response(parse_inspection_response(response.content), response.content)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: @conversation.account).capture_exception
    Rails.logger.warn("[LLA AI][AssistantActionClassifier] conversation=#{@conversation.display_id} error=#{e.class.name}")
    { 'action' => nil, 'action_reason' => nil, 'error' => e.message, 'model' => model }
  end

  private

  def model
    @model ||= Llm::FeatureRouter.resolve(feature: 'assistant', account: @assistant.account)[:model]
  end

  def chat
    RubyLLM.chat(model: model)
           .with_temperature(TEMPERATURE)
           .with_schema(Captain::AssistantActionSchema)
           .with_instructions(system_prompt)
  end

  def normalize_response(parsed, raw_content)
    action = parsed['action'].to_s
    reason = parsed['action_reason'].to_s
    return invalid_response(raw_content) unless Captain::AssistantActionSchema::ACTIONS.include?(action)
    return invalid_response(raw_content) unless Captain::AssistantActionSchema::REASONS.include?(reason)

    { 'action' => action, 'action_reason' => reason, 'raw_response' => raw_content, 'model' => model }
  end

  def invalid_response(raw_content)
    {
      'action' => nil,
      'action_reason' => nil,
      'raw_response' => raw_content,
      'error' => 'invalid_classifier_response',
      'model' => model
    }
  end

  def custom_instructions
    @assistant.config&.[]('instructions')
  end

  def system_prompt
    Captain::Llm::SystemPromptsService.assistant_action_classifier(has_custom_instructions: custom_instructions.present?)
  end

  def instrumentation_params(user_prompt)
    {
      span_name: 'llm.captain.assistant_action_classifier',
      model: model,
      temperature: TEMPERATURE,
      account_id: @conversation.account_id,
      conversation_id: @conversation.display_id,
      feature_name: 'assistant_action_classifier',
      messages: [{ role: 'system', content: system_prompt }, { role: 'user', content: user_prompt }],
      metadata: {
        assistant_id: @assistant.id,
        channel_type: @conversation.inbox&.channel_type,
        source: 'v1_response_builder'
      }
    }
  end
end
