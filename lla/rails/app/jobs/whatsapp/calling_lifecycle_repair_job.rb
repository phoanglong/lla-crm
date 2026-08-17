# frozen_string_literal: true

class Whatsapp::CallingLifecycleRepairJob < ApplicationJob
  queue_as :low

  def perform(account_id = nil)
    repair_scope(account_id).find_each { |channel| repair(channel) }
  end

  private

  def repair_scope(account_id)
    scope = Channel::Whatsapp.where(provider: 'whatsapp_cloud')
                             .where("provider_config ? 'calling_requested_enabled'")
    account_id.present? ? scope.where(account_id: account_id) : scope
  end

  def repair(channel)
    config = channel.provider_config || {}
    desired = ActiveModel::Type::Boolean.new.cast(config['calling_requested_enabled'])
    effective = ActiveModel::Type::Boolean.new.cast(config['calling_enabled'])
    return if config['calling_lifecycle_state'] == 'ready' && desired == effective

    operation = recoverable_operation(channel, config['calling_request_digest'], desired)
    Whatsapp::CallingLifecycleJob.perform_later(operation.id) if operation
  end

  def recoverable_operation(channel, request_digest, desired)
    return if request_digest.blank?

    action = desired ? 'enable_calling' : 'disable_calling'
    operation = Lla::Voice::CallOperation.where(account: channel.account, inbox: channel.inbox,
                                                action: action, request_digest: request_digest)
                                         .where.not(state: 'succeeded').order(created_at: :desc).first
    return operation if operation

    Lla::Voice::CallOperation.create_or_find_by!(
      account: channel.account,
      inbox: channel.inbox,
      idempotency_digest: digest("whatsapp-calling-repair:#{channel.id}:#{request_digest}:#{Time.current.utc.strftime('%Y%m%d%H')}")
    ) do |record|
      record.action = action
      record.state = 'pending'
      record.request_digest = request_digest
      record.available_at = Time.current
    end
  end

  def digest(value)
    Digest::SHA256.hexdigest(value)
  end
end
