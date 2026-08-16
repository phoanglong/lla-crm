# frozen_string_literal: true

module Captain::Tools::Instrumentation
  include Integrations::LlmInstrumentationConstants

  def execute(**args)
    return super unless ChatwootApp.otel_enabled?

    instrument_without_content(args) { super }
  end

  private

  def instrument_without_content(args)
    span = nil
    execution_started = false
    execution_completed = false
    result = nil

    span = OpentelemetryConfig.tracer.start_span("llm.tool.#{name.to_s.byteslice(0, 120)}")
    record_safe_input(span, args)
    execution_started = true
    result = yield
    execution_completed = true
    record_safe_output(span, result)
    result
  rescue StandardError
    return result if execution_completed
    raise if execution_started

    yield
  ensure
    finish_span(span)
  end

  def record_safe_input(span, args)
    summary = {
      argument_count: args.length,
      argument_names: args.keys.map { |key| key.to_s.byteslice(0, 80) }.sort,
      input_bytes: args.to_json.bytesize
    }
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_TYPE, 'tool')
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_INPUT, summary.to_json)
  end

  def record_safe_output(span, result)
    summary = { output_type: result.class.name, output_bytes: result.to_s.bytesize }
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, summary.to_json)
  end

  def finish_span(span)
    span&.finish
  rescue StandardError
    nil
  end
end
