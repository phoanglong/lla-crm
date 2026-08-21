# frozen_string_literal: true

class Whatsapp::CallingLifecycleRequestService
  class InvalidRequest < StandardError; end
  class IdempotencyConflict < StandardError; end

  IDEMPOTENCY_PATTERN = /\A[A-Za-z0-9_.:-]{8,128}\z/

  def initialize(inbox:, user:, enabled:, idempotency_key:)
    @inbox = inbox
    @user = user
    @enabled = ActiveModel::Type::Boolean.new.cast(enabled)
    @idempotency_key = idempotency_key
  end

  def perform
    validate_context!
    return response('ready') if already_ready?

    operation = create_or_find_operation
    enqueue = claim_request(operation)
    Whatsapp::CallingLifecycleJob.perform_later(operation.id) if enqueue
    response(operation.state)
  end

  private

  attr_reader :inbox, :user, :enabled, :idempotency_key

  def validate_context!
    raise InvalidRequest, 'Idempotency-Key required' unless IDEMPOTENCY_PATTERN.match?(idempotency_key.to_s)
    raise InvalidRequest, 'Inbox does not support WhatsApp calling' unless channel.is_a?(Channel::Whatsapp) &&
                                                                           channel.voice_calling_supported?
    raise InvalidRequest, 'Voice feature is not enabled' unless inbox.account.feature_enabled?('channel_voice')
    raise Pundit::NotAuthorizedError unless inbox.account.account_users.find_by(user_id: user.id)&.administrator?
  end

  def already_ready?
    config = channel.provider_config || {}
    requested = ActiveModel::Type::Boolean.new.cast(config['calling_requested_enabled'])
    effective = ActiveModel::Type::Boolean.new.cast(config['calling_enabled'])
    config['calling_lifecycle_state'] == 'ready' && requested == enabled && effective == enabled
  end

  def create_or_find_operation
    Lla::Voice::CallOperation.create_or_find_by!(
      account: inbox.account,
      inbox: inbox,
      idempotency_digest: digest("whatsapp-calling:#{idempotency_key}")
    ) do |record|
      record.action = enabled ? 'enable_calling' : 'disable_calling'
      record.state = 'pending'
      record.request_digest = request_digest
      record.available_at = Time.current
    end
  end

  def claim_request(operation)
    enqueue = false
    operation.with_lock do
      raise IdempotencyConflict, 'Idempotency-Key was used for another request' if operation.request_digest != request_digest

      next if operation.state == 'succeeded' || operation.active_claim?
      next if operation.retry_delayed?

      persist_requested_state!
      operation.update!(state: 'pending', completed_at: nil, last_error_code: nil)
      enqueue = true
    end
    enqueue
  end

  def persist_requested_state!
    channel.with_lock do
      config = (channel.provider_config || {}).merge(
        'calling_requested_enabled' => enabled,
        'calling_request_digest' => request_digest,
        'calling_lifecycle_state' => 'pending',
        'calling_lifecycle_error_code' => nil
      )
      config['calling_enabled'] = false
      channel.provider_config = config
      channel.save!(validate: false)
    end
    inbox.update_account_cache
  end

  def request_digest
    @request_digest ||= digest([inbox.account_id, inbox.id, channel.id, enabled].join(':'))
  end

  def response(state)
    { calling_requested_enabled: enabled, calling_lifecycle_state: state }
  end

  def channel
    @channel ||= inbox.channel
  end

  def digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
