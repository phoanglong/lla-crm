# frozen_string_literal: true

module Lla::CopilotMessageQuota
  def reserve_response!
    with_lock do
      next true if response_reserved? || response_processing?
      next false unless user? && response_none?

      token = SecureRandom.uuid
      quota = response_quota_manager(token)
      next false unless quota.reserve!.acquired?

      persist_response_reservation!(quota, token)
      true
    end
  end

  def complete_response!
    with_lock do
      next true if response_completed?
      next false unless response_processing?
      raise ActiveRecord::RecordInvalid, self unless response_quota_manager.consume!

      update!(response_state: :completed, response_completed_at: Time.current)
      true
    end
  end

  def release_response!
    with_lock do
      next false unless response_reserved? || response_processing?
      next false unless response_quota_manager.release!

      update!(response_state: :released, response_completed_at: Time.current)
      true
    end
  end

  private

  def persist_response_reservation!(quota, token)
    update!(response_state: :reserved, response_job_token: token, response_reserved_at: Time.current)
  rescue StandardError
    quota.release!
    raise
  end

  def response_quota_manager(owner_token = response_job_token)
    route = Llm::FeatureRouter.resolve(feature: 'copilot', account: account)
    Lla::Captain::QuotaManager.new(
      account: account,
      idempotency_key: "copilot-message:#{id}",
      owner_token: owner_token,
      feature: 'copilot',
      provider: route[:provider],
      credential_source: 'system',
      reason: 'copilot_response'
    )
  end
end
