# frozen_string_literal: true

class Whatsapp::CallActionOperation
  CLAIM_TTL = 2.minutes

  def initialize(call:, agent:, action:, sdp_answer: nil, recording_consent: nil)
    @call = call
    @agent = agent
    @action = action
    @sdp_answer = sdp_answer
    @recording_consent = recording_consent
  end

  def claim!
    validate_agent!
    operation = find_or_create_operation
    completed = false
    call.with_lock do
      raise Voice::CallErrors::CallFailed, 'Call action idempotency conflict' if operation.request_digest != request_digest

      completed = operation.state == 'succeeded'
      next if completed

      raise Voice::CallErrors::CallFailed, 'Call action retry is temporarily unavailable' if retry_delayed?(operation)
      raise Voice::CallErrors::CallFailed, 'Another call action is in progress' if competing_operation?(operation)
      raise Voice::CallErrors::CallFailed, 'Call action retry budget exhausted' if operation.retry_exhausted?

      validate_action_state!
      operation.update!(state: 'claimed', claimed_at: Time.current, completed_at: nil,
                        attempts: operation.attempts + 1, request_digest: request_digest, last_error_code: nil)
      @claimed = true
    end
    [operation, completed]
  end

  def complete!(operation)
    operation.update!(state: 'succeeded', completed_at: Time.current)
    @claimed = false
  end

  def fail!(operation, error)
    return unless @claimed && operation&.state == 'claimed'

    operation.update!(state: 'failed', completed_at: Time.current, last_error_code: error.class.name.first(80),
                      available_at: 30.seconds.from_now)
    @claimed = false
  end

  def compensate!(operation)
    return unless @claimed && operation&.state == 'claimed'

    operation.update!(state: 'compensating')
    call.inbox.channel.provider_service.terminate_call(call.provider_call_id)
    operation.update!(state: 'compensated', completed_at: Time.current)
    @claimed = false
  rescue StandardError => e
    operation.update!(state: 'failed', completed_at: Time.current, last_error_code: e.class.name.first(80),
                      available_at: 30.seconds.from_now)
    @claimed = false
  end

  private

  attr_reader :call, :agent, :action, :sdp_answer, :recording_consent

  def validate_agent!
    allowed = call.account.account_users.find_by(user_id: agent.id)&.administrator? || call.inbox.members.exists?(id: agent.id)
    raise Pundit::NotAuthorizedError unless allowed
  end

  def find_or_create_operation
    Lla::Voice::CallOperation.create_or_find_by!(
      account: call.account,
      inbox: call.inbox,
      idempotency_digest: digest("whatsapp:#{action}:#{call.id}")
    ) do |record|
      record.call = call
      record.action = action
      record.state = 'pending'
      record.request_digest = request_digest
      record.available_at = Time.current
    end
  end

  def competing_operation?(operation)
    call.lla_call_operations.where(state: 'claimed').where.not(id: operation.id)
        .exists?(['claimed_at > ?', CLAIM_TTL.ago])
  end

  def retry_delayed?(operation)
    operation.state == 'failed' && operation.available_at > Time.current
  end

  def validate_action_state!
    return unless action == 'accept'

    raise Voice::CallErrors::AlreadyAccepted, 'Call already accepted by another agent' if call.in_progress?
    raise Voice::CallErrors::CallAlreadyEnded, 'Call already ended' if call.terminal?
    raise Voice::CallErrors::NotRinging, 'Call is not in ringing state' unless call.ringing?
  end

  def request_digest
    answer_digest = digest(sdp_answer) if action == 'accept'
    consent_digest = Lla::Voice::RecordingConsentService.payload_digest(recording_consent) if action == 'accept'
    digest([action, call.id, agent.id, answer_digest, consent_digest].compact.join(':'))
  end

  def digest(value) = Digest::SHA256.hexdigest(value.to_s)
end
