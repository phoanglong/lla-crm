# frozen_string_literal: true

module Lla::Captain::BaseTaskService
  def perform
    return super unless lla_quota_enforced?

    result = lla_quota_manager.reserve!
    return lla_quota_error(result) unless result.acquired?

    response = super
    lla_successful_result?(response) ? lla_quota_manager.consume! : lla_quota_manager.release!
    response
  rescue StandardError
    lla_quota_manager&.release!
    raise
  end

  def with_quota_idempotency_key(key, owner_token: SecureRandom.uuid)
    @lla_quota_idempotency_key = key
    @lla_quota_owner_token = owner_token
    self
  end

  private

  def lla_quota_enforced?
    return false unless captain_tasks_enabled?

    Lla::Captain::QuotaPolicy.billable?(
      workload: counts_toward_usage? ? :customer_response : :internal,
      credential_source: lla_quota_credential_source
    )
  end

  def lla_quota_manager
    @lla_quota_manager ||= Lla::Captain::QuotaManager.new(
      account: account,
      idempotency_key: @lla_quota_idempotency_key || "captain-task:#{self.class.name}:#{SecureRandom.uuid}",
      owner_token: @lla_quota_owner_token || SecureRandom.uuid,
      feature: lla_quota_feature,
      provider: lla_quota_provider,
      credential_source: lla_quota_credential_source,
      reason: 'captain_task_execution'
    )
  end

  def lla_quota_feature
    event_name.to_s.presence || self.class.name.underscore
  end

  def lla_quota_provider
    return lla_quota_route[:provider] if lla_quota_route

    Llm::Models.provider_for(self.class.const_defined?(:GPT_MODEL) ? self.class::GPT_MODEL : Llm::Config::DEFAULT_MODEL)
  end

  # Nguồn khoá được đọc từ chính route của tính năng, vì mô hình mới là thứ quyết định gọi
  # bằng khoá nào: chọn `noi-bo/llama-3.1-70b` là gọi bằng khoá của tenant, kể cả khi tài
  # khoản không hề có hook OpenAI nào.
  def lla_quota_credential_source
    route_source = lla_quota_route&.dig(:credential)&.source
    return route_source.to_s if route_source == :account

    llm_credential&.dig(:source).to_s.presence || 'system'
  end

  def lla_quota_route
    return @lla_quota_route if defined?(@lla_quota_route)

    @lla_quota_route = Llm::Models.feature?(lla_quota_feature) ? Llm::FeatureRouter.resolve(feature: lla_quota_feature, account: account) : nil
  rescue Llm::FeatureRouter::UnknownFeatureError
    @lla_quota_route = nil
  end

  def lla_successful_result?(result)
    return false unless result.is_a?(Hash)

    success = (result[:message] || result['message']).present? || result[:success] == true || result['success'] == true
    success && !(result[:error] || result['error'])
  end

  def lla_quota_error(result)
    if result.rejected?
      { error: I18n.t('captain.copilot_limit'), error_code: 429, code: 'lla_quota_exhausted' }
    else
      { error: 'Duplicate Captain request', error_code: 409, code: result.status.to_s }
    end
  end
end
