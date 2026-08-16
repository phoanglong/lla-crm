# frozen_string_literal: true

# Validates and normalizes the assistant playground payload before it reaches an
# LLM service. Keeping the limits in the controller preserves the public API
# contract while this concern owns the input-boundary mechanics.
module Lla::Captain::AssistantPlaygroundParams
  private

  def playground_service
    if Current.account.feature_enabled?('captain_integration_v2')
      Captain::Assistant::AgentRunnerService.new(assistant: @assistant, source: 'playground')
    else
      Captain::Llm::AssistantChatService.new(assistant: @assistant, source: 'playground')
    end
  end

  def playground_arguments
    if Current.account.feature_enabled?('captain_integration_v2')
      { message_history: playground_history_with_current_message }
    else
      { additional_message: params[:message_content], message_history: playground_message_history }
    end
  end

  def playground_message_history
    @playground_message_history ||= Array(params[:message_history]).filter_map do |entry|
      next unless entry.is_a?(ActionController::Parameters) || entry.is_a?(Hash)

      entry = ActionController::Parameters.new(entry) unless entry.respond_to?(:permit)
      entry.permit(:role, :content, :agent_name).to_h.symbolize_keys
    end
  end

  def valid_playground_payload?
    history = playground_message_history
    valid_playground_message? && valid_playground_history?(history) && playground_history_bytes(history) <= playground_history_byte_limit
  end

  def valid_playground_message?
    message = params[:message_content]
    message.is_a?(String) && message.present? && message.bytesize <= self.class::MAX_PLAYGROUND_MESSAGE_BYTES
  end

  def valid_playground_history?(history)
    history.length == Array(params[:message_history]).length &&
      history.length <= self.class::MAX_PLAYGROUND_HISTORY_ITEMS &&
      history.all? { |entry| self.class::PLAYGROUND_ROLES.include?(entry[:role]) }
  end

  def playground_history_bytes(history)
    history.sum { |entry| entry.values.sum { |value| value.to_s.bytesize } }
  end

  def playground_history_byte_limit
    self.class::MAX_PLAYGROUND_HISTORY_BYTES
  end

  def render_invalid_playground
    render json: { error: 'Invalid or oversized playground message history' }, status: :unprocessable_entity
  end

  def playground_history_with_current_message
    history = playground_message_history
    current_message = { role: 'user', content: params[:message_content] }
    return history if history.last == current_message

    history + [current_message]
  end
end
