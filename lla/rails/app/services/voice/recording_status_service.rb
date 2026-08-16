class Voice::RecordingStatusService
  pattr_initialize [:account!, :inbox!, { payload: {} }]

  RECORDING_SID_PATTERN = /\ARE[A-Za-z0-9]{4,64}\z/

  def perform
    return unless completed_recording?
    return if conference_sid.blank? || !RECORDING_SID_PATTERN.match?(recording_sid)

    call = Call.where(account_id: account.id, inbox_id: inbox.id, provider: :twilio)
               .by_twilio_conference_sid(conference_sid).first
    return if call.blank?
    return unless recording_allowed?(call)

    Voice::Provider::Twilio::RecordingAttachmentJob.perform_later(
      call.id,
      recording_sid,
      recording_duration
    )
    call
  end

  private

  def completed_recording?
    payload['RecordingStatus'].to_s.casecmp('completed').zero?
  end

  def conference_sid
    payload['ConferenceSid'].to_s
  end

  def recording_sid
    payload['RecordingSid'].to_s
  end

  def recording_duration
    payload['RecordingDuration']
  end

  def recording_allowed?(call)
    enabled = ActiveModel::Type::Boolean.new.cast(inbox.channel.provider_config['voice_recording_enabled'])
    enabled && call.meta['recording_consent_id'].present?
  end
end
