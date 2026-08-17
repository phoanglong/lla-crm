# frozen_string_literal: true

class Lla::Voice::OperationReconciliationJob < ApplicationJob
  queue_as :low

  STALE_CLAIM_AGE = 5.minutes
  REPLAYABLE_ACTIONS = %w[enable_calling disable_calling].freeze

  def perform(account_id = nil)
    scope = Lla::Voice::CallOperation.all
    scope = scope.where(account_id: account_id) if account_id.present?
    recovered = recover_stale_claims(scope)
    replayed = replay_ready_operations(scope)
    exhausted_scope = scope.where(state: 'failed').where('attempts >= ?', Lla::Voice::CallOperation::MAX_ATTEMPTS)
    exhausted = exhausted_scope.count
    alert_exhausted_operations(exhausted_scope)
    Rails.logger.info(
      "LLA_VOICE_RECONCILIATION account=#{account_id || 'all'} recovered=#{recovered} " \
      "replayed=#{replayed} exhausted=#{exhausted}"
    )
  end

  private

  def recover_stale_claims(scope)
    recovered = 0
    scope.where(state: 'claimed').where('claimed_at < ?', STALE_CLAIM_AGE.ago).find_each do |operation|
      operation.with_lock do
        next unless operation.state == 'claimed' && operation.claimed_at < STALE_CLAIM_AGE.ago

        operation.update!(state: 'failed', completed_at: Time.current,
                          available_at: Time.current, claim_digest: nil, last_error_code: 'stale_claim')
        recovered += 1
      end
    end
    recovered
  end

  def replay_ready_operations(scope)
    replayed = 0
    scope.where(state: 'failed', action: REPLAYABLE_ACTIONS)
         .where('available_at <= ? AND attempts < ?', Time.current, Lla::Voice::CallOperation::MAX_ATTEMPTS).find_each do |operation|
      Whatsapp::CallingLifecycleJob.perform_later(operation.id)
      replayed += 1
    end
    replayed
  end

  def alert_exhausted_operations(scope)
    scope.group(:account_id).count.each do |account_id, count|
      key = "LLA_VOICE_EXHAUSTED_ALERT::#{account_id}:#{Time.current.utc.strftime('%Y%m%d')}"
      next unless Redis::Alfred.set(key, count, nx: true, ex: 1.day.to_i)

      error = StandardError.new("LLA voice operation retry budget exhausted count=#{count}")
      ChatwootExceptionTracker.new(error, account: Account.find(account_id)).capture_exception
    rescue StandardError => e
      Rails.logger.error("LLA_VOICE_RECONCILIATION_ALERT_FAILED account=#{account_id} error=#{e.class.name}")
    end
  end
end
