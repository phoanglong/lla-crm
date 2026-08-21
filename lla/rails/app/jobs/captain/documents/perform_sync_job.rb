# frozen_string_literal: true

# Sync lại nội dung một tài liệu web: tải trang nguồn, cập nhật nội dung +
# dấu vân; nội dung đổi sẽ tự kích hoạt sinh lại FAQ qua callback của Document.
# Khoá Redis theo tài liệu để hai worker không sync chồng nhau.
class Captain::Documents::PerformSyncJob < ApplicationJob
  LockUnavailable = Class.new(StandardError)
  queue_as :low

  LOCK_TIMEOUT = 30.minutes

  retry_on LockUnavailable, wait: 30.seconds, attempts: 5 do |job, _error|
    job.send(:release_exhausted_claim)
  end

  def perform(document, claim_token = nil)
    return unless document.syncable?
    return unless claim_authorized?(document, claim_token)

    acquired = with_lock(lock_key(document)) do
      document.reload
      next unless claim_authorized?(document, claim_token)

      document.update!(sync_status: :syncing, last_sync_attempted_at: Time.current)
      result = Captain::Documents::SinglePageFetcher.new(document.external_link).fetch

      result.success ? apply_sync(document, result, claim_token) : mark_sync_failed(document, 'fetch_failed', claim_token)
    end
    raise LockUnavailable, 'Captain document sync lock is busy' unless acquired
  rescue LockUnavailable
    raise
  rescue StandardError
    mark_sync_failed(document, 'sync_error', claim_token)
    raise
  end

  private

  def apply_sync(document, result, claim_token)
    document.reload
    return unless claim_authorized?(document, claim_token)

    document.update!(
      name: result.title.presence || document.name,
      content: result.content,
      content_fingerprint: Digest::SHA256.hexdigest(result.content.to_s),
      sync_status: :synced,
      last_sync_error_code: nil,
      last_synced_at: Time.current,
      last_sync_attempted_at: Time.current,
      sync_claim_digest: nil,
      sync_claimed_at: nil
    )
  end

  def mark_sync_failed(document, error_code, claim_token)
    document.reload
    return unless claim_authorized?(document, claim_token)

    document.update!(
      sync_status: :failed,
      last_sync_error_code: error_code,
      last_sync_attempted_at: Time.current,
      sync_claim_digest: nil,
      sync_claimed_at: nil
    )
  end

  def claim_authorized?(document, claim_token)
    stored = document.sync_claim_digest.to_s
    return stored.blank? if claim_token.blank?

    expected = Digest::SHA256.hexdigest("#{document.account_id}\0#{document.id}\0#{claim_token}")
    stored.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(stored, expected)
  end

  def with_lock(key, timeout: LOCK_TIMEOUT)
    return false unless Redis::Alfred.set(key, job_id, nx: true, ex: timeout.to_i)

    begin
      yield
      true
    ensure
      Redis::Alfred.delete_if_equals(key, job_id)
    end
  end

  def release_exhausted_claim
    document, claim_token = arguments
    document = Captain::Document.find_by(id: document.id)
    return unless document

    mark_sync_failed(document, 'lock_timeout', claim_token)
  rescue StandardError => e
    Rails.logger.error("LLA Captain sync claim cleanup failed document_id=#{document&.id} error_class=#{e.class.name}")
  end

  def lock_key(document)
    format('CAPTAIN_DOCUMENT_SYNC_LOCK::%d', document.id)
  end
end
