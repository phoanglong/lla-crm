# frozen_string_literal: true

class Whatsapp::CallingLifecycleJob < ApplicationJob
  queue_as :low

  retry_on StandardError, wait: 35.seconds, attempts: 5

  def perform(operation_id)
    operation = Lla::Voice::CallOperation.find(operation_id)
    validate_operation!(operation)
    return unless claim_operation(operation)

    channel = operation.inbox.channel
    return compensate_stale(operation) unless current_request?(channel, operation)
    return complete_operation(operation) if effective_state_ready?(channel, operation)

    apply_provider_state(channel, operation)
    finalize_state(channel, operation)
  rescue StandardError => e
    compensate_failed_enable(channel, operation)
    fail_operation(channel, operation, e) if operation
    raise
  end

  private

  def validate_operation!(operation)
    raise ArgumentError, 'Unsupported WhatsApp calling lifecycle operation' unless
      %w[enable_calling disable_calling].include?(operation.action)
    raise ArgumentError, 'Unsupported WhatsApp calling channel' unless operation.inbox.channel.is_a?(Channel::Whatsapp)
  end

  def claim_operation(operation)
    operation.with_lock do
      next false if operation.state == 'succeeded'
      next false if operation.active_claim?
      next false if operation.retry_delayed?
      raise 'WhatsApp calling lifecycle retry budget exhausted' if operation.retry_exhausted?

      operation.update!(state: 'claimed', claimed_at: Time.current, completed_at: nil,
                        attempts: operation.attempts + 1, last_error_code: nil)
      true
    end
  end

  def current_request?(channel, operation)
    config = channel.reload.provider_config || {}
    desired = ActiveModel::Type::Boolean.new.cast(config['calling_requested_enabled'])
    config['calling_request_digest'] == operation.request_digest && desired == enabling?(operation) &&
      (operation.action == 'disable_calling' || channel.account.feature_enabled?('channel_voice'))
  end

  def effective_state_ready?(channel, operation)
    config = channel.provider_config || {}
    effective = ActiveModel::Type::Boolean.new.cast(config['calling_enabled'])
    config['calling_lifecycle_state'] == 'ready' && effective == enabling?(operation)
  end

  def apply_provider_state(channel, operation)
    @provider_changed = true
    channel.provider_service.update_calling_status(enabling?(operation) ? 'ENABLED' : 'DISABLED')
    channel.provider_config = (channel.provider_config || {}).merge('calling_enabled' => enabling?(operation))
    Whatsapp::WebhookSetupService.new(channel).register_callback
  end

  def finalize_state(channel, operation)
    stale = false
    channel.reload
    channel.with_lock do
      stale = !current_request_without_reload?(channel, operation)
      next if stale

      config = channel.provider_config.merge(
        'calling_enabled' => enabling?(operation),
        'calling_lifecycle_state' => 'ready',
        'calling_lifecycle_error_code' => nil,
        'calling_lifecycle_updated_at' => Time.current.iso8601
      )
      channel.provider_config = config
      channel.save!(validate: false)
    end
    return compensate_stale(operation) if stale

    operation.inbox.update_account_cache
    complete_operation(operation)
  end

  def current_request_without_reload?(channel, operation)
    config = channel.provider_config || {}
    desired = ActiveModel::Type::Boolean.new.cast(config['calling_requested_enabled'])
    config['calling_request_digest'] == operation.request_digest && desired == enabling?(operation)
  end

  def complete_operation(operation)
    operation.update!(state: 'succeeded', completed_at: Time.current)
  end

  def compensate_stale(operation)
    compensate_provider_disable(operation.inbox.channel) if enabling?(operation) && @provider_changed
    operation.update!(state: 'compensated', completed_at: Time.current)
  end

  def compensate_failed_enable(channel, operation)
    return unless channel && operation && enabling?(operation) && @provider_changed

    compensate_provider_disable(channel)
  end

  def compensate_provider_disable(channel)
    channel.provider_service.update_calling_status('DISABLED')
  rescue StandardError => e
    Rails.logger.error(
      "LLA_WHATSAPP_CALLING_COMPENSATION_FAILED account=#{channel.account_id} channel=#{channel.id} error=#{e.class.name}"
    )
  end

  def fail_operation(channel, operation, error)
    operation.update!(state: 'failed', completed_at: Time.current,
                      last_error_code: error.class.name.first(80), available_at: 30.seconds.from_now)
    mark_channel_failed(channel, operation, error) if channel
    Rails.logger.error(
      "LLA_WHATSAPP_CALLING_LIFECYCLE_FAILED account=#{operation.account_id} inbox=#{operation.inbox_id} " \
      "action=#{operation.action} error=#{error.class.name}"
    )
  rescue StandardError
    nil
  end

  def mark_channel_failed(channel, operation, error)
    channel.with_lock do
      channel.reload
      next unless current_request_without_reload?(channel, operation)

      config = channel.provider_config.merge(
        'calling_lifecycle_state' => 'failed',
        'calling_lifecycle_error_code' => error.class.name.first(80),
        'calling_lifecycle_updated_at' => Time.current.iso8601
      )
      config['calling_enabled'] = false if enabling?(operation)
      channel.provider_config = config
      channel.save!(validate: false)
    end
  end

  def enabling?(operation)
    operation.action == 'enable_calling'
  end
end
