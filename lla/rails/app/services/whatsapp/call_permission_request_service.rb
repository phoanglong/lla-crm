# frozen_string_literal: true

# Sends Meta's call opt-in request without holding a database lock across the
# provider request and records only a digest of Meta's message identifier.
class Whatsapp::CallPermissionRequestService
  THROTTLE = 5.minutes
  PROVIDER_MESSAGE_ID_PATTERN = /\A[A-Za-z0-9_.:-]{4,512}\z/

  pattr_initialize [:conversation!, :user!]

  def perform
    validate_context!
    return 'permission_pending' if throttled?

    operation, disposition = claim_operation!
    return disposition if disposition

    provider_message_id = request_provider_permission!

    finalize_request!(operation, provider_message_id)
    emit_activity
    'permission_requested'
  rescue Pundit::NotAuthorizedError
    raise
  rescue StandardError => e
    fail_operation(operation, e)
    Rails.logger.warn(
      "LLA_WHATSAPP_PERMISSION_REQUEST_FAILED account=#{conversation.account_id} " \
      "inbox=#{conversation.inbox_id} error=#{e.class.name}"
    )
    'failed'
  end

  private

  def request_provider_permission!
    sent = provider_service.send_call_permission_request(destination, *body_args)
    provider_message_id = sent&.dig('messages', 0, 'id').to_s
    return provider_message_id if PROVIDER_MESSAGE_ID_PATTERN.match?(provider_message_id)

    raise Voice::CallErrors::CallFailed, 'WhatsApp call permission request failed'
  end

  def validate_context!
    channel = conversation.inbox.channel
    validate_user!
    validate_channel!(channel)
  end

  def validate_user!
    raise ArgumentError, 'Agent required' if user.blank?

    membership = conversation.account.account_users.find_by(user_id: user.id)
    allowed = membership&.administrator? || conversation.inbox.members.exists?(id: user.id)
    raise Pundit::NotAuthorizedError unless allowed
  end

  def validate_channel!(channel)
    raise ArgumentError, 'Unsupported voice channel' unless channel.is_a?(Channel::Whatsapp)
    raise ArgumentError, 'Voice is not enabled' unless
      conversation.account.feature_enabled?('channel_voice') && channel.voice_enabled?
  end

  def throttled?
    requested_at = conversation.reload.additional_attributes&.dig('call_permission_requested_at')
    parsed = Time.zone.parse(requested_at.to_s) if requested_at.present?
    parsed.present? && parsed > THROTTLE.ago
  rescue ArgumentError
    false
  end

  def claim_operation!
    operation = create_or_find_operation
    disposition = nil
    operation.with_lock do
      reconcile_request_digest!(operation)
      disposition = operation_disposition(operation)
      next if disposition

      operation.update!(state: 'claimed', claimed_at: Time.current, completed_at: nil,
                        attempts: operation.attempts + 1, last_error_code: nil)
      @claimed_operation = operation
    end
    [operation, disposition]
  end

  def reconcile_request_digest!(operation)
    return if operation.request_digest == request_digest

    raise Voice::CallErrors::CallFailed, 'Permission request payload changed' if active_claim?(operation) || throttled?

    operation.update!(request_digest: request_digest)
  end

  def operation_disposition(operation)
    return 'permission_pending' if (operation.state == 'succeeded' && throttled?) || active_claim?(operation)
    return 'failed' if operation.available_at.present? && operation.available_at > Time.current
  end

  def create_or_find_operation
    Lla::Voice::CallOperation.create_or_find_by!(
      account: conversation.account,
      inbox: conversation.inbox,
      idempotency_digest: digest("whatsapp:permission-request:#{conversation.id}")
    ) do |record|
      record.action = 'permission_request'
      record.state = 'pending'
      record.request_digest = request_digest
      record.available_at = Time.current
    end
  end

  def active_claim?(operation)
    operation.state == 'claimed' && operation.claimed_at.present? && operation.claimed_at > 2.minutes.ago
  end

  def finalize_request!(operation, provider_message_id)
    conversation.with_lock do
      attrs = (conversation.additional_attributes || {}).except('call_permission_request_message_id').merge(
        'call_permission_requested_at' => Time.current.iso8601,
        'call_permission_request_message_id_digest' => digest(provider_message_id)
      )
      conversation.update!(additional_attributes: attrs)
      operation.update!(state: 'succeeded', completed_at: Time.current,
                        provider_request_id_digest: digest(provider_message_id))
    end
    @claimed_operation = nil
  end

  def fail_operation(operation, error)
    return unless @claimed_operation && operation&.state == 'claimed'

    operation.update!(state: 'failed', completed_at: Time.current,
                      available_at: 30.seconds.from_now, last_error_code: error.class.name.first(80))
    @claimed_operation = nil
  rescue StandardError
    nil
  end

  def emit_activity
    content = I18n.t('conversations.activity.whatsapp_call.permission_requested', contact_name: conversation.contact.name)
    ::Conversations::ActivityMessageJob.perform_later(
      conversation,
      { account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity, content: content }
    )
  end

  def body_args
    custom_body = conversation.inbox.channel.provider_config&.dig('call_permission_request_body').presence
    custom_body ? [custom_body] : []
  end

  def request_digest
    @request_digest ||= digest([
      conversation.account_id, conversation.inbox_id, conversation.id, conversation.contact_id, body_args.first.to_s
    ].join(':'))
  end

  def destination
    conversation.contact.phone_number.to_s.delete('+')
  end

  def provider_service
    @provider_service ||= conversation.inbox.channel.provider_service
  end

  def digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
