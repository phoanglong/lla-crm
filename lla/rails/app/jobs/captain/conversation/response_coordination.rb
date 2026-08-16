# frozen_string_literal: true

module Captain::Conversation::ResponseCoordination
  private

  def valid_runtime_context?
    return false unless @conversation.persisted? && @assistant.persisted?
    return false unless @conversation.account_id == @assistant.account_id
    return false unless @inbox.account_id == @conversation.account_id

    configured_assistant = @inbox.captain_assistant
    configured_assistant.blank? || configured_assistant.id == @assistant.id
  end

  def valid_scheduling_token?
    @schedule_token = Redis::Alfred.get(@schedule_key)
    return true if @schedule_token.blank?

    scheduled_message_id = Lla::Captain::ResponseCoordination.scheduled_message_id(@schedule_token)
    return true if scheduled_message_id && scheduled_message_id <= latest_incoming_message_id.to_i

    Redis::Alfred.delete_if_equals(@schedule_key, @schedule_token)
    false
  end

  def acquire_execution_lock
    @execution_token = job_id.presence || SecureRandom.uuid
    @owns_execution = Redis::Alfred.set(
      @execution_key,
      @execution_token,
      nx: true,
      ex: Lla::Captain::ResponseCoordination::EXECUTION_TTL
    )
  end

  def response_still_current?
    return false unless conversation_pending?
    return true if latest_incoming_message_id == @starting_message_id

    mark_for_reschedule
    false
  end

  def latest_incoming_message_id
    @conversation.messages.where(account_id: @conversation.account_id).incoming.maximum(:id)
  end

  def human_replied_after_trigger?
    @conversation.messages.where(account_id: @conversation.account_id, message_type: :outgoing, sender_type: 'User')
                 .exists?(['id > ?', @starting_message_id])
  end

  def already_responded_to_trigger?
    @conversation.messages.where(account_id: @conversation.account_id, message_type: :outgoing)
                 .exists?(["additional_attributes ->> 'captain_source_message_id' = ?", @starting_message_id.to_s])
  end

  def mark_for_reschedule
    @reschedule_required = true if conversation_pending?
  end

  def release_coordination
    return unless @owns_execution

    Redis::Alfred.delete_if_equals(@execution_key, @execution_token)
    Redis::Alfred.delete_if_equals(@schedule_key, @schedule_token) if @schedule_token.present?
  rescue StandardError => e
    Rails.logger.error(
      "LLA Captain coordination release failed account_id=#{@conversation&.account_id} " \
      "conversation_id=#{@conversation&.id} error=#{e.class.name}"
    )
  end

  def reschedule_latest_response
    return unless rescheduling_allowed?

    latest_message = @conversation.messages.where(account_id: @conversation.account_id).incoming.last
    return unless latest_message

    enqueue_with_new_schedule_token(latest_message)
  rescue StandardError => e
    release_failed_reschedule_token
    ChatwootExceptionTracker.new(e, account: account).capture_exception if @conversation
  end

  def rescheduling_allowed?
    valid_runtime_context? && conversation_pending?
  end

  def enqueue_with_new_schedule_token(latest_message)
    @reschedule_token = Lla::Captain::ResponseCoordination.scheduling_token(latest_message.id)
    claimed = Redis::Alfred.set(
      @schedule_key,
      @reschedule_token,
      nx: true,
      ex: Lla::Captain::ResponseCoordination::SCHEDULE_TTL
    )
    enqueue_rescheduled_response(latest_message) if claimed
  end

  def release_failed_reschedule_token
    Redis::Alfred.delete_if_equals(@schedule_key, @reschedule_token) if @reschedule_token
  rescue StandardError
    nil
  end

  def enqueue_rescheduled_response(latest_message)
    if latest_message.attachments.blank?
      self.class.perform_later(@conversation, @assistant)
    else
      wait_time = 1.second + [latest_message.attachments.size, 4].min.seconds
      self.class.set(wait: wait_time).perform_later(@conversation, @assistant)
    end
  end

  def coordination_key(type)
    Lla::Captain::ResponseCoordination.public_send(
      "#{type}_key",
      account_id: @conversation.account_id,
      conversation_id: @conversation.id
    )
  end
end
