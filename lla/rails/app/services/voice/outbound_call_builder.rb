# frozen_string_literal: true

class Voice::OutboundCallBuilder
  class IdempotencyConflict < StandardError; end
  class OperationInProgress < StandardError; end

  CLAIM_TTL = 2.minutes
  IDEMPOTENCY_PATTERN = /\A[A-Za-z0-9_.:-]{8,128}\z/

  attr_reader :account, :inbox, :user, :contact

  def self.perform!(**arguments)
    new(**arguments).perform!
  end

  def initialize(account:, inbox:, user:, contact:, **options)
    @account = account
    @inbox = inbox
    @user = user
    @contact = contact
    @existing_conversation = options[:conversation]
    @idempotency_key = options[:idempotency_key]
  end

  def perform!
    validate_context!
    operation, prior_call = claim_operation!
    return prior_call if prior_call

    provider_call_sid = initiate_call!
    operation.update!(provider_request_id_digest: digest(provider_call_sid))
    finalize_call!(operation, provider_call_sid)
  rescue StandardError => e
    handle_failure(operation, provider_call_sid, e) if @claimed_operation
    raise
  end

  private

  def validate_context!
    raise ArgumentError, 'Contact phone number required' if contact.phone_number.blank?
    raise ArgumentError, 'Agent required' if user.blank?

    validate_idempotency_key!
    validate_tenant_context!
    validate_voice_channel!
  end

  def validate_idempotency_key!
    raise ArgumentError, 'Idempotency-Key required' unless IDEMPOTENCY_PATTERN.match?(@idempotency_key.to_s)
  end

  def validate_tenant_context!
    raise ArgumentError, 'Account context mismatch' unless context_associations_valid?
    raise Pundit::NotAuthorizedError unless caller_authorized?
  end

  def validate_voice_channel!
    raise ArgumentError, 'Voice is not enabled' unless account.feature_enabled?('channel_voice') && channel.voice_enabled?
    raise ArgumentError, 'Unsupported voice channel' unless channel.is_a?(Channel::TwilioSms)
  end

  def context_associations_valid?
    inbox.account_id == account.id && contact.account_id == account.id &&
      (@existing_conversation.nil? || valid_existing_conversation?)
  end

  def valid_existing_conversation?
    @existing_conversation.account_id == account.id && @existing_conversation.inbox_id == inbox.id &&
      @existing_conversation.contact_id == contact.id && @existing_conversation.open?
  end

  def caller_authorized?
    membership = account.account_users.find_by(user_id: user.id)
    membership&.administrator? || inbox.members.exists?(id: user.id)
  end

  def claim_operation!
    operation = create_or_find_operation!
    prior_call = nil

    operation.with_lock do
      raise IdempotencyConflict, 'Idempotency-Key was used for another request' if operation.request_digest != request_digest

      prior_call = operation.call if operation.state == 'succeeded' && operation.call.present?
      raise OperationInProgress, 'Call request is already in progress' if active_claim?(operation) && prior_call.nil?

      claim!(operation) if prior_call.nil?
    end

    [operation, prior_call]
  end

  def create_or_find_operation!
    Lla::Voice::CallOperation.create_or_find_by!(
      account: account,
      inbox: inbox,
      idempotency_digest: digest(@idempotency_key)
    ) do |record|
      record.action = 'dial'
      record.state = 'pending'
      record.request_digest = request_digest
      record.available_at = Time.current
    end
  end

  def claim!(operation)
    operation.update!(
      state: 'claimed',
      claim_digest: digest(SecureRandom.uuid),
      claimed_at: Time.current,
      completed_at: nil,
      last_error_code: nil,
      attempts: operation.attempts + 1
    )
    @claimed_operation = true
  end

  def active_claim?(operation)
    operation.state == 'claimed' && operation.claimed_at.present? && operation.claimed_at > CLAIM_TTL.ago
  end

  def request_digest
    @request_digest ||= digest([
      account.id, inbox.id, user.id, contact.id, contact.phone_number, @existing_conversation&.id
    ].join(':'))
  end

  def finalize_call!(operation, provider_call_sid)
    ActiveRecord::Base.transaction do
      contact_inbox = ensure_contact_inbox!
      conversation = @existing_conversation || create_conversation!(contact_inbox)
      claim_existing_conversation!(conversation) if @existing_conversation
      call = create_call!(conversation, provider_call_sid)
      message = Voice::CallMessageBuilder.new(call).perform!
      call.update!(message_id: message.id)
      operation.update!(state: 'succeeded', call: call, completed_at: Time.current, claim_digest: nil)
      call
    end
  end

  def ensure_contact_inbox!
    ContactInbox.find_or_create_by!(contact_id: contact.id, inbox_id: inbox.id) do |record|
      record.source_id = contact.phone_number
    end
  end

  def create_conversation!(contact_inbox)
    account.conversations.create!(contact_inbox_id: contact_inbox.id, inbox_id: inbox.id, contact_id: contact.id,
                                  assignee_id: user.id, status: :open)
  end

  def claim_existing_conversation!(conversation)
    conversation.with_lock { conversation.update!(assignee: user) if conversation.assignee_id.nil? }
  end

  def initiate_call!
    call_sid = channel.initiate_call(to: contact.phone_number)[:call_sid]
    raise 'Voice provider returned no call identifier' if call_sid.blank?

    call_sid
  end

  def create_call!(conversation, call_sid)
    Call.create!(
      account: account,
      inbox: inbox,
      conversation: conversation,
      contact: contact,
      accepted_by_agent: user,
      provider: :twilio,
      direction: :outgoing,
      status: 'ringing',
      provider_call_id: call_sid,
      meta: { 'initiated_at' => Time.zone.now.to_i }
    ).tap { |call| call.update!(conference_sid: call.default_conference_sid) }
  end

  def handle_failure(operation, provider_call_sid, error)
    return if operation.state == 'succeeded'

    if provider_call_sid.present?
      compensate_provider_call(operation, provider_call_sid, error)
    else
      mark_failed(operation, error)
    end
  rescue StandardError => e
    mark_failed(operation, e)
  end

  def compensate_provider_call(operation, provider_call_sid, error)
    operation.update!(state: 'compensating', last_error_code: error_code(error))
    Voice::Provider::Twilio::Adapter.new(channel).terminate_call(provider_call_sid)
    operation.update!(state: 'compensated', completed_at: Time.current, claim_digest: nil)
  end

  def mark_failed(operation, error)
    operation.update!(state: 'failed', completed_at: Time.current, claim_digest: nil,
                      last_error_code: error_code(error), available_at: 30.seconds.from_now)
  end

  def error_code(error)
    error.class.name.to_s.gsub(/[^A-Za-z0-9_:]/, '').first(80).presence || 'UnknownError'
  end

  def channel
    @channel ||= inbox.channel
  end

  def digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
