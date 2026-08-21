# frozen_string_literal: true

module Lla::Messages::AudioTranscriptionQuota
  private

  def transcription_credential_source
    account.hooks.find_by(app_id: 'openai', status: 'enabled')&.settings&.dig('api_key').present? ? :hook : :system
  end

  def transcription_billable?
    Lla::Captain::QuotaPolicy.billable?(workload: :customer_response, credential_source: transcription_credential_source)
  end

  def reserve_transcription_quota
    return true unless transcription_billable?

    result = transcription_quota_manager.reserve!
    @quota_reserved = result.acquired?
    @quota_denial = result.status unless @quota_reserved
    @quota_reserved
  end

  def consume_transcription_quota
    return true unless transcription_billable?

    @quota_settled = transcription_quota_manager.consume!
  end

  def release_transcription_quota
    return unless @quota_reserved

    @quota_settled = transcription_quota_manager.release!
  end

  def transcription_quota_manager
    @transcription_quota_manager ||= begin
      route = Llm::FeatureRouter.resolve(feature: 'audio_transcription', account: account)
      @transcription_quota_owner ||= SecureRandom.uuid
      Lla::Captain::QuotaManager.new(
        account: account,
        idempotency_key: "audio-transcription:#{attachment.id}",
        owner_token: @transcription_quota_owner,
        feature: 'audio_transcription',
        provider: route[:provider],
        credential_source: transcription_credential_source,
        reason: 'audio_transcription'
      )
    end
  end

  def quota_denial_message
    @quota_denial == :rejected ? 'Transcription limit exceeded' : 'Transcription already processing'
  end
end
