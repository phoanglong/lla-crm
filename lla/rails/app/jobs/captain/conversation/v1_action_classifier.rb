# frozen_string_literal: true

module Captain::Conversation::V1ActionClassifier
  private

  def v1_action_classifier_enabled?
    account.feature_enabled?('captain_v1_action_classifier')
  end

  def classify_v1_response_action(message_history)
    return unless v1_action_classifier_enabled?
    return if legacy_v1_handoff_token?

    classification = Captain::Llm::AssistantActionClassifierService.new(
      assistant: @assistant,
      conversation: @conversation
    ).classify(message_history: message_history, assistant_response: @response['response'])

    apply_v1_action_classification(classification)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: account).capture_exception
    Rails.logger.warn(
      "LLA Captain V1 action classifier failed account_id=#{account.id} " \
      "conversation_id=#{@conversation.id} error=#{e.class.name}"
    )
  end

  def apply_v1_action_classification(classification)
    action = classification['action']
    return log_invalid_v1_action_classification(classification) unless valid_v1_action_classification?(action)

    @response.merge!(
      'action' => action,
      'action_reason' => classification['action_reason'],
      'action_source' => 'classifier',
      'action_classifier_model' => classification['model']
    )

    log_v1_action_classification(action, classification)
  end

  def log_v1_action_classification(action, classification)
    Rails.logger.info(
      "LLA Captain V1 action classified account_id=#{account.id} conversation_id=#{@conversation.id} " \
      "action=#{action} reason=#{classification['action_reason']} model=#{classification['model']}"
    )
  end

  def valid_v1_action_classification?(action)
    Captain::AssistantActionSchema::ACTIONS.include?(action)
  end

  def log_invalid_v1_action_classification(classification)
    Rails.logger.warn(
      "LLA Captain V1 classifier invalid account_id=#{account.id} conversation_id=#{@conversation.id} " \
      "error=#{classification['error']} model=#{classification['model']}"
    )
  end
end
