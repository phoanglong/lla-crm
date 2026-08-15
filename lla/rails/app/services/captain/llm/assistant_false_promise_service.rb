# frozen_string_literal: true

# Soát câu trả lời dự kiến trước khi gửi: có hứa hẹn ngoài ngữ cảnh đã biết
# không. Luôn dùng model kiểm định cố định, không theo override của account.
class Captain::Llm::AssistantFalsePromiseService
  DETECTOR_MODEL = Llm::FeatureRouter::CAPTAIN_V2_ASSISTANT_MODEL

  def initialize(assistant:, conversation:)
    @assistant = assistant
    @conversation = conversation
  end

  def detect(message_history:, assistant_response:)
    response = chat.ask(detection_prompt(message_history, assistant_response))
    result_hash(response.content)
  rescue StandardError => e
    Rails.logger.error("AssistantFalsePromiseService error: #{e.message}")
    result_hash({ 'decision' => nil, 'reason' => nil, 'error' => e.message })
  end

  private

  def chat
    RubyLLM.chat(model: DETECTOR_MODEL)
           .with_schema(Captain::AssistantFalsePromiseSchema)
           .with_instructions(Captain::Llm::SystemPromptsService.assistant_false_promise_detector)
  end

  def detection_prompt(message_history, assistant_response)
    transcript = Array(message_history).map do |entry|
      data = entry.with_indifferent_access
      "#{data[:role].to_s.capitalize}: #{data[:content]}"
    end.join("\n")

    "<conversation_context>\n#{transcript}\n</conversation_context>\n\n" \
      "<assistant_response_to_check>\n#{assistant_response}\n</assistant_response_to_check>"
  end

  def result_hash(content)
    content.to_h.merge('model' => DETECTOR_MODEL)
  end
end
