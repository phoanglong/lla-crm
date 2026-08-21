# frozen_string_literal: true

class Whatsapp::RecordingAttachmentService
  class NotAllowed < StandardError; end
  class InvalidRecording < StandardError; end

  MAX_RECORDING_BYTES = 25.megabytes
  DEFAULT_EXTENSION = 'wav'

  pattr_initialize [:call!, :upload!]

  def perform
    validate_policy!
    return 'already_uploaded' if already_attached?

    validate_size!
    content_type = detect_content_type!
    scan!
    attach_idempotently!(content_type)
  ensure
    upload.tempfile.rewind if upload.respond_to?(:tempfile)
  end

  private

  def validate_policy!
    enabled = ActiveModel::Type::Boolean.new.cast(call.inbox.channel.provider_config['voice_recording_enabled'])
    raise NotAllowed, 'Voice recording is disabled or consent is missing' unless
      enabled && call.whatsapp? && call.meta&.dig('recording_consent_id').present?
  end

  def validate_size!
    raise InvalidRecording, 'Recording is empty' unless upload.respond_to?(:tempfile) && upload.tempfile.size.positive?
    raise InvalidRecording, 'Recording exceeds 25 MB' if upload.tempfile.size > MAX_RECORDING_BYTES
  end

  def detect_content_type!
    upload.tempfile.rewind
    content_type = Marcel::MimeType.for(upload.tempfile, name: upload.original_filename)
    raise InvalidRecording, 'Recording content is not audio' unless content_type&.start_with?('audio/')

    content_type
  ensure
    upload.tempfile.rewind
  end

  def scan!
    Lla::Security::MalwareScanner.scan!(upload.tempfile)
  end

  def attach_idempotently!(content_type)
    call.message.with_lock do
      next 'already_uploaded' if already_attached?

      call.message.attachments.create!(
        account_id: call.account_id,
        file_type: :audio,
        file: {
          io: upload.tempfile,
          filename: "whatsapp-call-recording-#{call.id}.#{extension_for(content_type)}",
          content_type: content_type
        }
      )
      'uploaded'
    end
  end

  def already_attached?
    call.message.attachments.exists?(file_type: :audio)
  end

  def extension_for(content_type)
    Rack::Mime::MIME_TYPES.invert[content_type].to_s.delete_prefix('.').presence || DEFAULT_EXTENSION
  end
end
