# frozen_string_literal: true

class Lla::Knowledge::GenerationRetentionCleanupJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 200
  FAILURE_VISIBILITY_PERIOD = 7.days

  def perform
    operation_ids.each { |operation_id| expire_operation(operation_id) }
  end

  private

  def operation_ids
    Lla::Knowledge::GenerationOperation.where(expires_at: ..Time.current)
                                       .order(:expires_at, :id).limit(BATCH_SIZE).pluck(:id)
  end

  def expire_operation(operation_id)
    operation = Lla::Knowledge::GenerationOperation.find_by(id: operation_id)
    return if operation.blank?
    return operation.destroy! if operation.terminal?

    Lla::Knowledge::GenerationStateService.new(operation).terminalize!(
      state: 'failed', error_code: 'retention_expired'
    )
    operation.with_lock do
      operation.outboxes.delete_all
      operation.update!(provider_consent_digests: {}, expires_at: FAILURE_VISIBILITY_PERIOD.from_now)
    end
  end
end
