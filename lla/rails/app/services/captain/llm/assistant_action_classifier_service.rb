# frozen_string_literal: true

# Phân loại hành động kế tiếp cho câu trả lời dự kiến của trợ lý
# (reply/handoff/…) bằng LLM với schema cứng.
class Captain::Llm::AssistantActionClassifierService
  def initialize(assistant:, conversation:)
    @assistant = assistant
    @conversation = conversation
  end

  def classify(message_history:, assistant_response:)
    response = chat.ask(classification_prompt(message_history, assistant_response))
    result_hash(response.content)
  rescue StandardError => e
    Rails.logger.error("AssistantActionClassifierService error: #{e.message}")
    result_hash({ 'action' => nil, 'action_reason' => nil, 'error' => e.message })
  end

  private

  def model
    @model ||= Llm::FeatureRouter.resolve(feature: 'assistant', account: @assistant.account)[:model]
  end

  def chat
    RubyLLM.chat(model: model)
           .with_schema(Captain::AssistantActionSchema)
           .with_instructions(
             Captain::Llm::SystemPromptsService.assistant_action_classifier(has_custom_instructions: custom_instructions.present?)
           )
  end

  def classification_prompt(message_history, assistant_response)
    sections = []
    sections << "<account_custom_instructions>\n#{custom_instructions}\n</account_custom_instructions>" if custom_instructions.present?
    sections << "<conversation_context>\n#{transcript(message_history)}\n</conversation_context>"
    sections << "<assistant_response_to_classify>\n#{assistant_response}\n</assistant_response_to_classify>"
    sections.join("\n\n")
  end

  def transcript(message_history)
    Array(message_history).map do |entry|
      data = entry.with_indifferent_access
      "#{data[:role].to_s.capitalize}: #{data[:content]}"
    end.join("\n")
  end

  def custom_instructions
    @assistant.config&.[]('instructions')
  end

  def result_hash(content)
    content.to_h.merge('model' => model)
  end
end
