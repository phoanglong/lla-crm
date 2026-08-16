class Voice::Provider::Twilio::ConferenceService
  pattr_initialize [:call!]

  def ensure_conference_sid
    return call.conference_sid if call.conference_sid.present?

    call.update!(conference_sid: call.default_conference_sid)
    call.conference_sid
  end

  def mark_agent_joined(user:)
    raise Pundit::NotAuthorizedError unless authorized_for_call?(user)

    claim_call!(user)
    assign_conversation!(user)
  end

  def end_conference
    return if call.conference_sid.blank?

    operation = termination_operation
    return unless claim_termination!(operation)

    terminate_provider_conferences
    complete_termination!(operation)
  rescue StandardError => e
    operation&.update!(state: 'failed', completed_at: Time.current, last_error_code: e.class.name.first(80))
    raise
  end

  private

  def claim_call!(user)
    call.with_lock do
      raise_already_accepted!(call.accepted_by_agent) if claimed_by_other_agent?(user)
      call.update!(accepted_by_agent: user) if call.accepted_by_agent_id != user.id
    end
  end

  def claimed_by_other_agent?(user)
    call.accepted_by_agent_id.present? && call.accepted_by_agent_id != user.id
  end

  def claim_termination!(operation)
    operation.with_lock do
      next false if operation.state == 'succeeded'
      next false if operation.state == 'claimed' && operation.claimed_at.present? && operation.claimed_at > 2.minutes.ago

      operation.update!(state: 'claimed', claimed_at: Time.current, attempts: operation.attempts + 1)
      true
    end
  end

  def terminate_provider_conferences
    client = call.inbox.channel.client
    conferences = client.conferences.list(friendly_name: call.conference_sid, status: 'in-progress')
    conferences.each { |conference| client.conferences(conference.sid).update(status: 'completed') }
  end

  def complete_termination!(operation)
    operation.update!(state: 'succeeded', completed_at: Time.current, claim_digest: nil)
  end

  def authorized_for_call?(user)
    membership = call.account.account_users.find_by(user_id: user.id)
    membership&.administrator? || call.inbox.members.exists?(id: user.id)
  end

  def termination_operation
    Lla::Voice::CallOperation.create_or_find_by!(
      account: call.account,
      inbox: call.inbox,
      idempotency_digest: Digest::SHA256.hexdigest("terminate:#{call.id}")
    ) do |record|
      record.call = call
      record.action = 'terminate'
      record.state = 'pending'
      record.request_digest = Digest::SHA256.hexdigest(call.conference_sid)
      record.available_at = Time.current
    end
  end

  def raise_already_accepted!(agent)
    raise CustomExceptions::CallAlreadyAccepted.new(agent_name: agent&.available_name || agent&.name)
  end

  # Existing assignments win — manual reassignment and pre-call assignment
  # (e.g., lock_to_single_conversation) shouldn't be stomped on pickup.
  def assign_conversation!(user)
    conversation = call.conversation
    return if conversation.assignee_id.present?

    Conversations::AssignmentService.new(conversation: conversation, assignee_id: user.id).perform
  end
end
