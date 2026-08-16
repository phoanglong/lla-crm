# frozen_string_literal: true

class Messages::AudioTranscriptionJob < ApplicationJob
  queue_as :low

  discard_on Faraday::BadRequestError do |job, error|
    Rails.logger.warn(
      "LLA audio transcription discarded attachment_id=#{job.arguments.first} job_id=#{job.job_id} " \
      "status=#{error.response&.dig(:status)} error=#{error.class.name}"
    )
  end
  retry_on ActiveStorage::FileNotFoundError, Faraday::ConnectionFailed, Faraday::TimeoutError,
           wait: 2.seconds, attempts: 3

  def perform(attachment_id)
    attachment = Attachment.find_by(id: attachment_id)
    return if attachment.blank?

    Messages::AudioTranscriptionService.new(attachment).perform
  end
end
