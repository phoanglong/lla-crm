# frozen_string_literal: true

# V2 remains optional until Wave E4 is LLA-owned. A stale feature flag must not
# silently downgrade an account to V1 or load EE-only constants in pure LLA.
module Captain::Conversation::V2Runtime
  class RuntimeUnavailableError < StandardError; end

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
    return false if tenant_ai_provider_route?

    available = v2_runtime_constants.all?(&:safe_constantize)
    return true if available

    log_missing_v2_runtime
    raise RuntimeUnavailableError, 'Captain V2 runtime is unavailable'
  end

  # Đường chạy V2 dùng gem `agents`, mà gem này cấu hình RubyLLM **toàn cục** lúc khởi động:
  # không có chỗ nào để đưa khoá của một tenant vào một lượt chạy. Tenant đã chọn mô hình của
  # nhà cung cấp riêng thì chạy V2 nghĩa là lặng lẽ gọi bằng khoá của LLA — sai cả về khoá lẫn
  # về tiền. Rơi về đường V1, nơi credential đi theo từng lệnh gọi.
  def tenant_ai_provider_route?
    route = Llm::FeatureRouter.resolve(feature: 'assistant', account: account)
    route[:credential]&.source == :account
  rescue Llm::FeatureRouter::UnknownFeatureError
    false
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
      "LLA Captain V2 runtime unavailable; handing off account_id=#{account.id} conversation_id=#{@conversation.id}"
    )
  end
end
