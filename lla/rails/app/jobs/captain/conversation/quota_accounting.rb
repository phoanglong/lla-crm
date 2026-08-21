# frozen_string_literal: true

module Captain::Conversation::QuotaAccounting
  private

  def reserve_response_quota
    result = response_quota_manager.reserve!
    @quota_reserved = result.acquired?
    @quota_denial = result.status unless @quota_reserved
    @quota_reserved
  end

  def consume_response_quota
    consumed = response_quota_manager.consume!
    @quota_settled = consumed
    consumed
  end

  def release_response_quota
    return unless @quota_reserved

    @quota_settled = response_quota_manager.release!
  end

  def handle_quota_denial
    Rails.logger.info(
      "LLA Captain response skipped account_id=#{account.id} conversation_id=#{@conversation.id} reason=#{@quota_denial}"
    )
    return if @quota_denial != :rejected || !delivery_allowed?

    @response = { 'action_source' => 'quota', 'action_reason' => 'quota_exhausted' }
    process_v1_handoff
  end

  def response_quota_manager
    @response_quota_manager ||= begin
      route = Llm::FeatureRouter.resolve(feature: 'assistant', account: account)
      Lla::Captain::QuotaManager.new(
        account: account,
        idempotency_key: "captain-response-job:#{job_id}",
        owner_token: job_id,
        feature: 'assistant',
        provider: route[:provider],
        credential_source: 'system',
        reason: 'automated_conversation_response'
      )
    end
  end

  def release_quota_after_retry_exhaustion
    conversation = arguments.first
    return unless conversation.respond_to?(:account)

    @conversation = conversation
    response_quota_manager.release!
  rescue StandardError => e
    Rails.logger.error("LLA Captain quota cleanup failed job_id=#{job_id} error=#{e.class.name}")
  end
end
