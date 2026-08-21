# frozen_string_literal: true

module Captain::Assistant::RunnerCallbacksHelper
  private

  def add_callbacks_to_runner(configured_runner)
    configured_runner = add_callback(configured_runner, :on_agent_thinking) if @callbacks[:on_agent_thinking]
    configured_runner = add_callback(configured_runner, :on_tool_start) if @callbacks[:on_tool_start]
    configured_runner = add_callback(configured_runner, :on_tool_complete) if @callbacks[:on_tool_complete]
    configured_runner = add_callback(configured_runner, :on_agent_handoff) if @callbacks[:on_agent_handoff]
    configured_runner
  end

  def register_trace_input_callback(configured_runner)
    configured_runner.on_agent_thinking do |_agent_name, _input, context_wrapper|
      tracing = context_wrapper&.context&.dig(:__otel_tracing)
      next unless tracing

      trace_summary = context_wrapper.context[:captain_v2_trace_current_input]
      tracing[:pending_llm_input] = trace_summary if trace_summary.present?
    end
  end

  def add_callback(configured_runner, event)
    configured_runner.public_send(event) do |*args|
      @callbacks[event].call(*args)
    rescue StandardError => e
      Rails.logger.warn("LLA Captain callback failed event=#{event} error=#{e.class.name}")
    end
  end
end
