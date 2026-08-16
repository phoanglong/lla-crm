class Voice::Provider::Twilio::RecordingAttachmentService
  DEFAULT_FILENAME_EXTENSION = 'wav'.freeze
  ALLOWED_CONTENT_TYPE_PREFIXES = %w[audio/].freeze
  MAX_RECORDING_BYTES = 25.megabytes
  RECORDING_SID_PATTERN = /\ARE[A-Za-z0-9]{4,64}\z/
  ACCOUNT_SID_PATTERN = /\AAC[A-Za-z0-9]{4,64}\z/

  pattr_initialize [:call!, :recording_sid!, { recording_duration: nil }]

  def perform
    return unless provider_identity_valid? && recording_allowed?
    return if already_attached?

    SafeFetch.fetch(
      recording_url,
      http_basic_authentication: [account_sid, auth_token],
      allowed_content_type_prefixes: ALLOWED_CONTENT_TYPE_PREFIXES,
      max_bytes: MAX_RECORDING_BYTES
    ) do |result|
      validate_download!(result)
      persist_recording!(result)
    end

    # Bump the message updated_at so the message.updated dispatcher rebroadcasts
    # the embedded Call payload (now with recording_url) to connected clients.
    call.message&.touch # rubocop:disable Rails/SkipsModelValidations
  end

  private

  def validate_download!(result)
    result.tempfile.rewind
    @detected_content_type = Marcel::MimeType.for(result.tempfile, name: result.original_filename)
    raise SafeFetch::UnsupportedContentTypeError, 'recording content is not audio' unless @detected_content_type&.start_with?('audio/')

    result.tempfile.rewind
    Lla::Security::MalwareScanner.scan!(result.tempfile)
    result.tempfile.rewind
  end

  def persist_recording!(result)
    call.with_lock do
      next if already_attached?

      attach_recording!(result)
      call.recording_sid = recording_sid
      call.duration_seconds ||= normalized_recording_duration
      call.save!
    end
  end

  def already_attached?
    call.recording.attached? && call.recording_sid.to_s == recording_sid.to_s
  end

  def attach_recording!(result)
    call.recording.attach(
      io: result.tempfile,
      filename: recording_filename(result),
      content_type: recording_content_type(result)
    )
  end

  def normalized_recording_duration
    return if recording_duration.blank?

    duration = Integer(recording_duration, exception: false)
    duration if duration&.between?(0, 24.hours.to_i)
  end

  def recording_filename(result)
    "call-recording-#{call.id}.#{recording_extension(result)}"
  end

  def recording_extension(result)
    content_type = recording_content_type(result)
    Rack::Mime::MIME_TYPES.invert[content_type].to_s.delete_prefix('.').presence || DEFAULT_FILENAME_EXTENSION
  end

  def recording_content_type(result)
    @detected_content_type.presence || result.content_type.presence || 'audio/wav'
  end

  def account_sid
    @account_sid ||= channel.account_sid
  end

  def auth_token
    @auth_token ||= channel.auth_token
  end

  def channel
    @channel ||= call.inbox.channel
  end

  def recording_url
    "https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Recordings/#{recording_sid}"
  end

  def recording_allowed?
    enabled = ActiveModel::Type::Boolean.new.cast(channel.provider_config['voice_recording_enabled'])
    enabled && call.meta['recording_consent_id'].present?
  end

  def provider_identity_valid?
    RECORDING_SID_PATTERN.match?(recording_sid.to_s) && ACCOUNT_SID_PATTERN.match?(account_sid.to_s)
  end
end
