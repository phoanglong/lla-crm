# frozen_string_literal: true

module Captain::ChatGenerationRecorder
  include Integrations::LlmInstrumentationConstants

  private

  def record_llm_generation(chat, message)
    return unless ChatwootApp.otel_enabled? && valid_llm_message?(message)

    tracer.in_span("llm.captain.#{feature_name}.generation") do |span|
      safe_generation_attributes(chat, message).each { |key, value| span.set_attribute(key, value) unless value.nil? }
    end
  rescue StandardError => e
    Rails.logger.warn("LLA chat generation telemetry failed service=#{self.class.name} error=#{e.class.name}")
  end

  def valid_llm_message?(message)
    message.respond_to?(:role) && message.role.to_s == 'assistant'
  end

  def safe_generation_attributes(chat, message)
    messages = Array(chat.messages)[0...-1]
    {
      ATTR_GEN_AI_PROVIDER => safe_provider_name(model),
      ATTR_GEN_AI_REQUEST_MODEL => model.to_s.byteslice(0, 120).to_s.scrub,
      ATTR_GEN_AI_REQUEST_TEMPERATURE => temperature,
      ATTR_GEN_AI_USAGE_INPUT_TOKENS => message.respond_to?(:input_tokens) ? message.input_tokens : nil,
      ATTR_GEN_AI_USAGE_OUTPUT_TOKENS => message.respond_to?(:output_tokens) ? message.output_tokens : nil,
      ATTR_LANGFUSE_OBSERVATION_INPUT => { message_count: messages.length, input_bytes: message_bytes(messages) }.to_json,
      ATTR_LANGFUSE_OBSERVATION_OUTPUT => { output_bytes: safe_message_content(message).bytesize }.to_json,
      format(ATTR_LANGFUSE_OBSERVATION_METADATA, 'generation_stage') => generation_stage(message)
    }
  end

  def safe_provider_name(model_name)
    model = model_name.to_s.downcase
    LlmConstants::PROVIDER_PREFIXES.each do |provider, prefixes|
      return provider.to_s if prefixes.any? { |prefix| model.start_with?(prefix) }
    end
    'openai'
  end

  def message_bytes(messages)
    messages.sum { |item| item.respond_to?(:content) ? item.content.to_s.bytesize : 0 }
  end

  def safe_message_content(message)
    message.respond_to?(:content) ? message.content.to_s : ''
  end

  def generation_stage(message)
    message.respond_to?(:tool_calls) && message.tool_calls.respond_to?(:any?) && message.tool_calls.any? ? 'tool_call' : 'final_response'
  end

  def tracer
    @tracer ||= OpentelemetryConfig.tracer
  end
end
