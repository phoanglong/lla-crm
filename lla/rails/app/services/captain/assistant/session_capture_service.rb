# frozen_string_literal: true

class Captain::Assistant::SessionCaptureService
  SCENARIO_AGENT_REGEX = /\A#{Captain::Scenario::HANDOFF_KEY_PREFIX}_(\d+)_/
  MAX_CAPTURED_MESSAGES = 20
  MAX_CAPTURED_CONTENT_BYTES = 4_096

  def initialize(assistant:, conversation:, run_result:, result_message:, credits_consumed:)
    @assistant = assistant
    @conversation = conversation
    @run_result = run_result
    @result_message = result_message
    @credits_consumed = credits_consumed
  end

  def capture
    return unless @run_result&.success? && valid_runtime_context?

    capture!
  rescue ActiveRecord::RecordNotUnique
    existing_session
  rescue StandardError => e
    capture_sanitized_exception(e)
    Rails.logger.error(
      "LLA Captain session capture failed account_id=#{@assistant&.account_id} " \
      "conversation_id=#{@conversation&.id} error=#{e.class.name}"
    )
    nil
  end

  def capture!
    model = @assistant.agent_model

    Captain::AgentSession.create!(
      assistant: @assistant,
      session_type: :assistant,
      subject: @conversation,
      result: result_message,
      llm_model: "#{Llm::Models.provider_for(model)}-#{model}".byteslice(0, 255),
      credits_consumed: bounded_credits,
      faq_ids: bounded_ids(metadata[:faq_ids]),
      document_ids: bounded_ids(metadata[:document_ids]),
      scenario_ids: scenario_ids,
      run_context: { messages: current_turn_history }
    )
  end

  private

  def valid_runtime_context?
    valid_records? && matching_accounts? && configured_inbox?
  end

  def valid_records?
    @assistant&.persisted? && @conversation&.persisted?
  end

  def matching_accounts?
    @assistant.account_id == @conversation.account_id && @conversation.inbox&.account_id == @assistant.account_id
  end

  def configured_inbox?
    CaptainInbox.exists?(inbox_id: @conversation.inbox_id, captain_assistant_id: @assistant.id)
  end

  def context
    @run_result.context || {}
  end

  def metadata
    @metadata ||= context.dig(:state, :cw_metadata) || {}
  end

  def result_message
    handoff_note || @result_message
  end

  def handoff_note
    note_id = metadata[:handoff_note_id]
    return if note_id.blank?

    @conversation.messages.find_by(id: note_id, account_id: @assistant.account_id)
  end

  def scenario_ids
    ids = current_turn_history.filter_map do |message|
      next unless message[:role].to_s == 'assistant'

      message[:agent_name].to_s.match(SCENARIO_AGENT_REGEX)&.[](1)&.to_i
    end.uniq

    @assistant.scenarios.where(id: ids).pluck(:id)
  end

  def current_turn_history
    history = Array(context[:conversation_history])
    last_user_index = history.rindex { |message| message[:role].to_s == 'user' }
    current_turn = last_user_index ? history[last_user_index..] : history

    current_turn.last(MAX_CAPTURED_MESSAGES).filter_map { |message| sanitized_history_message(message) }
  end

  def sanitized_history_message(message)
    return unless message.is_a?(Hash)

    {
      role: message[:role].to_s.byteslice(0, 20),
      content: sanitized_content(message[:content]),
      agent_name: message[:agent_name].to_s.byteslice(0, 120).presence,
      tool_call_id: message[:tool_call_id].to_s.byteslice(0, 120).presence
    }.compact
  end

  def sanitized_content(content)
    return sanitized_ruby_llm_content(content) if content.is_a?(RubyLLM::Content)

    content.to_s.byteslice(0, MAX_CAPTURED_CONTENT_BYTES).to_s.scrub
  end

  def sanitized_ruby_llm_content(content)
    {
      text: content.text.to_s.byteslice(0, MAX_CAPTURED_CONTENT_BYTES).to_s.scrub,
      attachments: Array.new(content.attachments.length.clamp(0, 6)) { { type: 'image' } }
    }
  end

  def bounded_ids(values)
    Array(values).filter_map { |value| Integer(value, exception: false) }.select(&:positive?).uniq.first(100)
  end

  def bounded_credits
    value = Float(@credits_consumed, exception: false)
    value&.finite? && value >= 0 ? [value, 1_000_000].min : 0.0
  end

  def existing_session
    return unless result_message

    Captain::AgentSession.find_by(
      account_id: @assistant.account_id,
      result_type: result_message.class.base_class.name,
      result_id: result_message.id
    )
  end

  def capture_sanitized_exception(error)
    sanitized = StandardError.new("Captain session capture failure: #{error.class.name}")
    ChatwootExceptionTracker.new(sanitized, account: @assistant&.account).capture_exception
  rescue StandardError
    nil
  end
end
