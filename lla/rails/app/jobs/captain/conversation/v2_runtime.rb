# frozen_string_literal: true

# V2 remains optional until Wave E4 is LLA-owned. Feature flags cannot make an
# EE-only constant load in pure-LLA mode; unavailable V2 safely falls back to V1.
module Captain::Conversation::V2Runtime
  private

  def generate_response_with_v2
    runner_service = Captain::Assistant::AgentRunnerService.new(assistant: @assistant, conversation: @conversation)
    message_history = Captain::Conversation::MessageHistoryBuilderService.new(conversation: @conversation).perform
    @response = runner_service.generate_response(message_history: message_history)
    @run_result = runner_service.last_run_result
    validate_response!
    return mark_for_reschedule unless v2_handoff_tool_fired? || response_still_current?

    process_response
  end

  def process_v2_handoff_result
    conversation_pending? ? process_v1_handoff : process_v2_handoff
    capture_assistant_session(result_message: @handoff_message, credits_consumed: 0.0)
  end

  def process_v2_handoff
    return if human_replied_after_trigger? || already_responded_to_trigger?

    I18n.with_locale(@assistant.account.locale) do
      create_handoff_message(preserve_waiting_since: true)
    end
  end

  def capture_assistant_session(result_message:, credits_consumed:)
    capture_service = 'Captain::Assistant::SessionCaptureService'.safe_constantize
    return unless capture_service

    capture_service.new(
      assistant: @assistant,
      conversation: @conversation,
      run_result: @run_result,
      result_message: result_message,
      credits_consumed: credits_consumed
    ).capture
  end

  def captain_v2_enabled?
    return false unless account.feature_enabled?('captain_integration_v2')

    available = v2_runtime_constants.all?(&:safe_constantize)
    log_missing_v2_runtime unless available
    available
  end

  def v2_runtime_constants
    %w[
      Captain::Assistant::AgentRunnerService
      Captain::Conversation::MessageHistoryBuilderService
      Captain::Assistant::SessionCaptureService
    ]
  end

  def log_missing_v2_runtime
    Rails.logger.warn(
      "LLA Captain V2 runtime unavailable; using V1 account_id=#{account.id} conversation_id=#{@conversation.id}"
    )
  end
end
