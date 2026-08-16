class Voice::Provider::Twilio::RecordingAttachmentJob < ApplicationJob
  queue_as :low

  retry_on Down::Error, SafeFetch::FetchError, SafeFetch::HttpError,
           Lla::Security::MalwareScanner::ScannerUnavailable, wait: :polynomially_longer, attempts: 5
  discard_on SafeFetch::UnsupportedContentTypeError, SafeFetch::FileTooLargeError,
             Lla::Security::MalwareScanner::ThreatDetected

  def perform(call_id, recording_sid, recording_duration = nil)
    call = Call.find_by(id: call_id)
    return if call.blank?

    operation = find_or_create_operation(call, recording_sid, recording_duration)
    return unless claim_operation(operation)

    Voice::Provider::Twilio::RecordingAttachmentService.new(
      call: call,
      recording_sid: recording_sid,
      recording_duration: recording_duration
    ).perform
    operation.update!(state: 'succeeded', completed_at: Time.current, claim_digest: nil)
  rescue StandardError => e
    operation&.update!(state: 'failed', completed_at: Time.current, claim_digest: nil,
                       last_error_code: e.class.name.first(80), available_at: 30.seconds.from_now)
    raise
  end

  private

  def find_or_create_operation(call, recording_sid, recording_duration)
    Lla::Voice::CallOperation.create_or_find_by!(
      account: call.account,
      inbox: call.inbox,
      idempotency_digest: digest([call.id, recording_sid].join(':'))
    ) do |record|
      record.call = call
      record.action = 'fetch_recording'
      record.state = 'pending'
      record.request_digest = digest([recording_sid, recording_duration].join(':'))
      record.available_at = Time.current
    end
  end

  def claim_operation(operation)
    operation.with_lock do
      next false if operation.state == 'succeeded'
      next false if operation.state == 'claimed' && operation.claimed_at.present? && operation.claimed_at > 2.minutes.ago

      operation.update!(state: 'claimed', claimed_at: Time.current, completed_at: nil,
                        attempts: operation.attempts + 1, last_error_code: nil)
      true
    end
  end

  def digest(value)
    Digest::SHA256.hexdigest(value)
  end
end
