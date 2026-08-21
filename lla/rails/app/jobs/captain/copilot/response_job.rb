# frozen_string_literal: true

class Captain::Copilot::ResponseJob < ApplicationJob
  ThreadBusyError = Class.new(StandardError)
  GenerationError = Class.new(StandardError)
  LOCK_TTL = 2.minutes.to_i
  LOCK_KEY = 'LLA_COPILOT_THREAD_LOCK::%<account_id>d::%<thread_id>d'

  queue_as :default

  retry_on ThreadBusyError, wait: 2.seconds, attempts: 10 do |job, _error|
    job.send(:release_exhausted_reservation)
  end
  retry_on GenerationError, wait: :polynomially_longer, attempts: 3 do |job, _error|
    job.send(:release_exhausted_reservation)
  end

  def perform(message_id:, reservation_token:)
    assign_context(message_id, reservation_token)
    execute_response if @source_message.present? && !terminal_response?
  rescue ThreadBusyError
    raise
  rescue StandardError => e
    return if @source_message&.reload&.response_completed?

    handle_generation_error(e)
    raise GenerationError, e.class.name
  ensure
    Current.executed_by = nil
    release_thread_lock
  end

  private

  def execute_response
    return release_invalid_context unless valid_runtime_context?

    acquire_thread_lock!
    @source_message.reload
    return release_invalid_context unless valid_runtime_context?

    execute_claim(@source_message.claim_response!(@reservation_token))
  end

  def execute_claim(claim)
    return if claim.in?(%i[finished invalid])
    raise ThreadBusyError, 'Earlier Copilot response is pending' if claim == :out_of_order

    @claimed = true
    Current.executed_by = @assistant
    Captain::Copilot::ChatService.new(@source_message).generate_response
  end

  def assign_context(message_id, reservation_token)
    @source_message = CopilotMessage.includes(copilot_thread: %i[account user assistant]).find_by(id: message_id)
    return if @source_message.blank?

    @reservation_token = reservation_token.to_s
    @copilot_thread = @source_message.copilot_thread
    @account = @copilot_thread.account
    @user = @copilot_thread.user
    @assistant = @copilot_thread.assistant
    @lock_token = job_id.presence || SecureRandom.uuid
  end

  def terminal_response?
    @source_message.response_completed? || @source_message.response_released?
  end

  def valid_runtime_context?
    return false unless @source_message.user? && @source_message.account_id == @account.id
    return false unless @assistant.account_id == @account.id && @copilot_thread.user_id == @user.id
    return false unless AccountUser.exists?(account_id: @account.id, user_id: @user.id)
    return true if @source_message.conversation.blank?

    permissible_conversations.exists?(id: @source_message.conversation_id)
  end

  def permissible_conversations
    Conversations::PermissionFilterService.new(@account.conversations, @user, @account).perform
  end

  def acquire_thread_lock!
    @lock_key = format(LOCK_KEY, account_id: @account.id, thread_id: @copilot_thread.id)
    @owns_lock = Redis::Alfred.set(@lock_key, @lock_token, nx: true, ex: LOCK_TTL)
    raise ThreadBusyError, 'Copilot thread is busy' unless @owns_lock
  end

  def release_thread_lock
    return unless @owns_lock

    Redis::Alfred.delete_if_equals(@lock_key, @lock_token)
  rescue StandardError => e
    Rails.logger.error(
      "LLA Copilot lock release failed account_id=#{@account&.id} thread_id=#{@copilot_thread&.id} error=#{e.class.name}"
    )
  end

  def release_invalid_context
    return unless @source_message.send(:reservable_token?, @reservation_token)

    @source_message.release_response!
    @source_message.persist_failure_response!
    Rails.logger.warn(
      "LLA Copilot job rejected message_id=#{@source_message.id} account_id=#{@source_message.account_id} reason=invalid_context"
    )
  end

  def handle_generation_error(error)
    @source_message.reset_response_for_retry!(@reservation_token) if @claimed
    safe_error = StandardError.new("Copilot generation failed: #{error.class.name}")
    ChatwootExceptionTracker.new(safe_error, account: @account).capture_exception
    Rails.logger.error(
      "LLA Copilot generation failed account_id=#{@account&.id} thread_id=#{@copilot_thread&.id} " \
      "message_id=#{@source_message&.id} error=#{error.class.name}"
    )
  end

  def release_exhausted_reservation
    arguments = self.arguments.first.to_h.with_indifferent_access
    message = CopilotMessage.find_by(id: arguments[:message_id])
    return if message.blank? || message.response_completed? || message.response_released?

    token = arguments[:reservation_token].to_s
    return unless message.send(:reservable_token?, token)

    message.release_response!
    message.persist_failure_response!
  rescue StandardError => e
    Rails.logger.error("LLA Copilot reservation cleanup failed message_id=#{arguments&.[](:message_id)} error=#{e.class.name}")
  end
end
