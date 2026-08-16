# frozen_string_literal: true

class Whatsapp::OutboundCallBuilder
  class InvalidRequest < StandardError; end
  class IdempotencyConflict < StandardError; end
  class OperationInProgress < StandardError; end

  IDEMPOTENCY_PATTERN = /\A[A-Za-z0-9_.:-]{8,128}\z/
  PROVIDER_CALL_ID_PATTERN = /\A[A-Za-z0-9_.:-]{4,255}\z/

  def initialize(account:, inbox:, user:, contact:, **options)
    @account = account
    @inbox = inbox
    @user = user
    @contact = contact
    @conversation_builder = options[:conversation_builder]
    @conversation = options[:conversation]
    @sdp_offer = options[:sdp_offer]
    @idempotency_key = options[:idempotency_key]
  end

  def perform!
    validate_context!
    operation, prior_call = claim_operation!
    return prior_call if prior_call

    provider_call_id = initiate_provider_call!
    operation.update!(provider_request_id_digest: digest(provider_call_id))
    finalize_call!(operation, provider_call_id)
  rescue StandardError => e
    handle_failure(operation, provider_call_id, e) if @claimed_operation
    raise
  end

  private

  attr_reader :account, :inbox, :user, :contact, :conversation_builder, :sdp_offer

  def validate_context!
    raise InvalidRequest, 'Idempotency-Key required' unless IDEMPOTENCY_PATTERN.match?(@idempotency_key.to_s)

    validate_tenant!
    validate_channel!
    raise Pundit::NotAuthorizedError unless authorized_user?

    Lla::Voice::SdpStore.validate!('offer', sdp_offer)
  rescue ArgumentError => e
    raise InvalidRequest, e.message
  end

  def validate_tenant!
    raise InvalidRequest, 'Account context mismatch' unless inbox.account_id == account.id && contact.account_id == account.id
  end

  def validate_channel!
    raise InvalidRequest, 'Unsupported voice channel' unless inbox.channel.is_a?(Channel::Whatsapp)
    raise InvalidRequest, 'Voice is not enabled' unless account.feature_enabled?('channel_voice') && inbox.channel.voice_enabled?
  end

  def authorized_user?
    membership = account.account_users.find_by(user_id: user.id)
    membership&.administrator? || inbox.members.exists?(id: user.id)
  end

  def claim_operation!
    operation = create_or_find_operation!
    prior_call = nil
    operation.with_lock do
      validate_request_digest!(operation)
      prior_call = completed_call(operation)
      validate_claimable!(operation) unless prior_call
      claim!(operation) if prior_call.nil?
    end
    [operation, prior_call]
  end

  def validate_request_digest!(operation)
    return if operation.request_digest == request_digest

    raise IdempotencyConflict, 'Idempotency-Key was used for another request'
  end

  def completed_call(operation)
    operation.call if operation.state == 'succeeded' && operation.call.present?
  end

  def validate_claimable!(operation)
    raise OperationInProgress, 'Call request is already in progress' if active_claim?(operation)
    raise OperationInProgress, 'Call request retry is temporarily unavailable' if retry_delayed?(operation)
  end

  def create_or_find_operation!
    Lla::Voice::CallOperation.create_or_find_by!(
      account: account, inbox: inbox, idempotency_digest: digest(@idempotency_key)
    ) do |record|
      record.action = 'dial'
      record.state = 'pending'
      record.request_digest = request_digest
      record.available_at = Time.current
    end
  end

  def claim!(operation)
    operation.update!(state: 'claimed', claimed_at: Time.current, completed_at: nil,
                      attempts: operation.attempts + 1, last_error_code: nil)
    @claimed_operation = true
  end

  def active_claim?(operation)
    operation.state == 'claimed' && operation.claimed_at.present? && operation.claimed_at > 2.minutes.ago
  end

  def retry_delayed?(operation)
    operation.state == 'failed' && operation.available_at.present? && operation.available_at > Time.current
  end

  def request_digest
    @request_digest ||= digest([
      'whatsapp', account.id, inbox.id, user.id, contact.id, @conversation&.id, digest(sdp_offer)
    ].join(':'))
  end

  def initiate_provider_call!
    result = inbox.channel.provider_service.initiate_call(contact.phone_number.delete('+'), sdp_offer)
    provider_call_id = result.dig('calls', 0, 'id') || result['call_id']
    raise Voice::CallErrors::CallFailed, 'WhatsApp call provider returned an invalid response' unless
      PROVIDER_CALL_ID_PATTERN.match?(provider_call_id.to_s)

    provider_call_id
  end

  def finalize_call!(operation, provider_call_id)
    ActiveRecord::Base.transaction do
      conversation = @conversation || conversation_builder.perform!
      claim_conversation!(conversation)
      call = create_call!(conversation, provider_call_id)
      message = call.message || Voice::CallMessageBuilder.new(call).perform!
      call.update!(message_id: message.id) if call.message_id != message.id
      operation.update!(state: 'succeeded', call: call, completed_at: Time.current)
      call
    end
  end

  def claim_conversation!(conversation)
    conversation.with_lock { conversation.update!(assignee: user) if conversation.assignee_id.nil? }
  end

  def create_call!(conversation, provider_call_id)
    Call.create!(
      account: account,
      provider: :whatsapp,
      inbox: conversation.inbox,
      conversation: conversation,
      contact: conversation.contact,
      provider_call_id: provider_call_id,
      direction: :outgoing,
      status: 'ringing',
      accepted_by_agent: user,
      meta: { 'sdp_offer_digest' => digest(sdp_offer) }
    )
  rescue ActiveRecord::RecordNotUnique
    existing = Call.find_by_provider_call_id(account: account, inbox: inbox, provider: :whatsapp,
                                             provider_call_id: provider_call_id)
    raise unless existing
    raise Voice::CallErrors::CallFailed, 'WhatsApp call identifier collision' unless
      existing.conversation_id == conversation.id && existing.contact_id == contact.id

    existing
  end

  def handle_failure(operation, provider_call_id, error)
    return if operation.state == 'succeeded'

    if provider_call_id.present?
      operation.update!(state: 'compensating', last_error_code: error.class.name.first(80))
      inbox.channel.provider_service.terminate_call(provider_call_id)
      operation.update!(state: 'compensated', completed_at: Time.current)
    else
      operation.update!(state: 'failed', completed_at: Time.current, last_error_code: error.class.name.first(80),
                        available_at: 30.seconds.from_now)
    end
  rescue StandardError => e
    operation.update!(state: 'failed', completed_at: Time.current, last_error_code: e.class.name.first(80))
  end

  def digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
