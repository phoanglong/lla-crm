# frozen_string_literal: true

# Queue audio transcription for LLA-owned media handling. The callback is kept
# in one extension only so EE ON does not enqueue the same attachment twice.
module Lla::Concerns::Attachment
  extend ActiveSupport::Concern

  included do
    after_create_commit :enqueue_lla_audio_transcription
    after_create_commit :broadcast_lla_audio_attachment
  end

  private

  def enqueue_lla_audio_transcription
    return unless audio?

    Messages::AudioTranscriptionJob.perform_later(id)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: account).capture_exception
    Rails.logger.error("LLA audio transcription enqueue failed account_id=#{account_id} attachment_id=#{id} error=#{e.class.name}")
    raise
  end

  def broadcast_lla_audio_attachment
    return unless audio? && message.present? && file.attached?

    message.reload.send_update_event
  end
end
