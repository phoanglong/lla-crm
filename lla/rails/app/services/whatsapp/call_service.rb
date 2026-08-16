# frozen_string_literal: true

class Whatsapp::CallService
  pattr_initialize [:call!, :agent!, :sdp_answer]

  def accept
    validate_sdp_answer!
    operation, completed = claim_action!('accept')
    return call if completed

    invoke_provider!(:pre_accept_call, sdp_answer)
    invoke_provider!(:accept_call, sdp_answer)
    finalize_accept!(operation)
  rescue StandardError => e
    fail_operation(operation, e)
    raise
  end

  def reject
    return call if call.terminal? || call.in_progress?

    operation, completed = claim_action!('reject')
    return call if completed

    invoke_provider!(:reject_call)
    finalize_terminal!(operation, 'rejected', end_reason: 'agent_rejected')
  rescue StandardError => e
    fail_operation(operation, e)
    raise
  end

  def terminate
    return call if call.terminal?

    operation, completed = claim_action!('terminate')
    return call if completed

    invoke_provider!(:terminate_call)
    call.reload
    target = call.in_progress? ? 'completed' : 'no_answer'
    duration = call.started_at ? [(Time.current - call.started_at).to_i, 0].max : nil
    finalize_terminal!(operation, target, duration_seconds: duration, end_reason: 'agent_hangup')
  rescue StandardError => e
    fail_operation(operation, e)
    raise
  end

  private

  def validate_sdp_answer!
    Lla::Voice::SdpStore.validate!('answer', sdp_answer)
  rescue ArgumentError
    raise Voice::CallErrors::CallFailed, 'sdp_answer is required'
  end

  def claim_action!(action)
    @action_operation = Whatsapp::CallActionOperation.new(call: call, agent: agent, action: action,
                                                          sdp_answer: sdp_answer)
    @action_operation.claim!
  end

  def invoke_provider!(method, *)
    success = call.inbox.channel.provider_service.public_send(method, call.provider_call_id, *)
    raise Voice::CallErrors::CallFailed, 'WhatsApp call provider request failed' unless success
  rescue Voice::CallErrors::CallFailed
    raise
  rescue StandardError => e
    Rails.logger.error(
      "LLA_WHATSAPP_CALL_PROVIDER_FAILED account=#{call.account_id} inbox=#{call.inbox_id} " \
      "action=#{method} error=#{e.class.name}"
    )
    raise Voice::CallErrors::CallFailed, 'WhatsApp call provider request failed'
  end

  def finalize_accept!(operation)
    answer_digest = Lla::Voice::SdpStore.write(call: call, kind: 'answer', sdp: sdp_answer)
    ActiveRecord::Base.transaction do
      result = call.transition_to!('in_progress', from_status: 'ringing', accepted_by_agent: agent)
      handle_accept_race! unless result == :applied
      call.update!(meta: (call.meta || {}).except('sdp_answer', 'sdp_offer').merge('sdp_answer_digest' => answer_digest))
      assign_conversation
      update_message_status('in_progress')
      complete_operation(operation)
    end
    broadcast(:accepted, accepted_by_agent_id: agent.id)
    call
  rescue StandardError
    compensate_provider_call(operation)
    raise
  end

  def handle_accept_race!
    call.reload
    return if call.in_progress? && call.accepted_by_agent_id == agent.id

    raise Voice::CallErrors::CallAlreadyEnded, 'Call already ended' if call.terminal?

    raise Voice::CallErrors::AlreadyAccepted, 'Call already accepted by another agent'
  end

  def finalize_terminal!(operation, status, **attributes)
    stale = false
    ActiveRecord::Base.transaction do
      status, stale = resolve_terminal_transition(status, attributes)
      finalize_terminal_records!(operation, status, attributes) unless stale
    end
    handle_terminal_race!(operation) if stale

    delete_sdp
    broadcast(:ended, status: call.display_status)
    call
  end

  def resolve_terminal_transition(status, attributes)
    return [status, false] if call.transition_to!(status, **attributes) == :applied

    call.reload
    [call.status, !call.terminal?]
  end

  def finalize_terminal_records!(operation, status, attributes)
    call.update!(accepted_by_agent: agent) if status == 'rejected' && call.accepted_by_agent_id.nil?
    update_message_status(status, duration_seconds: attributes[:duration_seconds])
    complete_operation(operation)
  end

  def handle_terminal_race!(operation)
    call.reload
    return if call.terminal?

    error = Voice::CallErrors::CallFailed.new('Call state changed while the provider action was in progress')
    fail_operation(operation, error)
    raise error
  end

  def assign_conversation
    conversation = call.conversation
    return if conversation.assignee_id.present?

    Conversations::AssignmentService.new(conversation: conversation, assignee_id: agent.id).perform
  end

  def update_message_status(status, duration_seconds: nil)
    Voice::CallMessageBuilder.new(call).update_status!(status: status, agent: agent, duration_seconds: duration_seconds)
  end

  def broadcast(event, **extra)
    token = agent.pubsub_token
    return if token.blank?

    payload = {
      event: "voice_call.#{event}",
      data: { id: call.id, call_id: call.provider_call_id, provider: call.provider,
              conversation_id: call.conversation_id, account_id: call.account_id }.merge(extra)
    }
    ActionCable.server.broadcast(token, payload)
  rescue StandardError => e
    Rails.logger.warn(
      "LLA_WHATSAPP_CALL_BROADCAST_FAILED account=#{call.account_id} inbox=#{call.inbox_id} error=#{e.class.name}"
    )
  end

  def delete_sdp
    Lla::Voice::SdpStore.delete(call: call)
  rescue StandardError => e
    Rails.logger.warn(
      "LLA_WHATSAPP_SDP_DELETE_FAILED account=#{call.account_id} inbox=#{call.inbox_id} error=#{e.class.name}"
    )
  end

  def complete_operation(operation)
    @action_operation.complete!(operation)
  end

  def compensate_provider_call(operation)
    @action_operation&.compensate!(operation)
  end

  def fail_operation(operation, error)
    @action_operation&.fail!(operation, error)
  end
end
