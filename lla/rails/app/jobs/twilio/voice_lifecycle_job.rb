# frozen_string_literal: true

class Twilio::VoiceLifecycleJob < ApplicationJob
  queue_as :low

  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(channel_id, action, configuration_digest)
    channel = Channel::TwilioSms.find(channel_id)
    validate_action!(action)
    operation = find_or_create_operation(channel, action, configuration_digest)
    return unless claim_operation(operation)

    unless current_configuration?(channel, action, configuration_digest)
      compensate_operation(operation)
      return
    end

    action == 'provision' ? provision(channel, operation, configuration_digest) : teardown(channel, operation)
  rescue StandardError => e
    fail_operation(operation, e) if operation
    raise
  end

  private

  def validate_action!(action)
    raise ArgumentError, 'Unsupported voice lifecycle action' unless %w[provision teardown].include?(action)
  end

  def find_or_create_operation(channel, action, configuration_digest)
    Lla::Voice::CallOperation.create_or_find_by!(
      account: channel.account,
      inbox: channel.inbox,
      idempotency_digest: digest([action, channel.id, configuration_digest].join(':'))
    ) do |record|
      record.action = action
      record.state = 'pending'
      record.request_digest = configuration_digest
      record.available_at = Time.current
    end
  end

  def claim_operation(operation)
    operation.with_lock do
      next false if operation.state == 'succeeded'
      next false if active_claim?(operation)

      operation.update!(state: 'claimed', claimed_at: Time.current, completed_at: nil,
                        attempts: operation.attempts + 1, last_error_code: nil)
      true
    end
  end

  def active_claim?(operation)
    operation.state == 'claimed' && operation.claimed_at.present? && operation.claimed_at > 2.minutes.ago
  end

  def current_configuration?(channel, action, expected_digest)
    expected_state = action == 'provision'
    current = channel.reload
    feature_allowed = action == 'teardown' || current.account.feature_enabled?('channel_voice')
    current.voice_configuration_digest == expected_digest && current.voice_enabled? == expected_state && feature_allowed
  end

  def provision(channel, operation, configuration_digest)
    app_sid = Twilio::VoiceWebhookSetupService.new(channel: channel).perform
    if persist_provisioned_app(channel, app_sid, configuration_digest)
      complete_operation(operation)
    else
      compensate_app(channel, app_sid)
      compensate_operation(operation)
    end
  rescue StandardError
    compensate_app(channel, app_sid) if app_sid.present?
    raise
  end

  def persist_provisioned_app(channel, app_sid, configuration_digest)
    channel.with_lock do
      channel.reload
      current = channel.voice_enabled? && channel.voice_configuration_digest == configuration_digest
      next false unless current

      channel.update!(twiml_app_sid: app_sid)
      true
    end
  end

  def teardown(channel, operation)
    Twilio::VoiceTeardownService.new(channel: channel).perform
    complete_operation(operation)
  end

  def compensate_app(channel, app_sid)
    channel.client.applications(app_sid).delete
  rescue StandardError => e
    Rails.logger.error(
      "LLA_TWILIO_VOICE_COMPENSATION_FAILED account=#{channel.account_id} channel=#{channel.id} " \
      "error=#{e.class.name} code=#{provider_error_code(e)}"
    )
  end

  def complete_operation(operation)
    operation.update!(state: 'succeeded', completed_at: Time.current, claim_digest: nil)
  end

  def compensate_operation(operation)
    operation.update!(state: 'compensated', completed_at: Time.current, claim_digest: nil)
  end

  def fail_operation(operation, error)
    operation.update!(state: 'failed', completed_at: Time.current, claim_digest: nil,
                      last_error_code: error.class.name.first(80), available_at: 30.seconds.from_now)
  end

  def provider_error_code(error)
    error.respond_to?(:code) ? error.code.to_s.gsub(/[^A-Za-z0-9_-]/, '').first(40) : 'none'
  end

  def digest(value)
    Digest::SHA256.hexdigest(value)
  end
end
