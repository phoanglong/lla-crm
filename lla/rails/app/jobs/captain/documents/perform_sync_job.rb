# frozen_string_literal: true

# Sync lại nội dung một tài liệu web: tải trang nguồn, cập nhật nội dung +
# dấu vân; nội dung đổi sẽ tự kích hoạt sinh lại FAQ qua callback của Document.
# Khoá Redis theo tài liệu để hai worker không sync chồng nhau.
class Captain::Documents::PerformSyncJob < ApplicationJob
  queue_as :low

  LOCK_TIMEOUT = 30.minutes

  def perform(document)
    return unless document.syncable?

    with_lock(lock_key(document)) do
      document.update!(sync_status: :syncing, last_sync_attempted_at: Time.current)
      result = Captain::Documents::SinglePageFetcher.new(document.external_link).fetch

      result.success ? apply_sync(document, result) : mark_sync_failed(document, 'fetch_failed')
    end
  rescue StandardError
    mark_sync_failed(document, 'sync_error')
    raise
  end

  private

  def apply_sync(document, result)
    document.update!(
      name: result.title.presence || document.name,
      content: result.content,
      content_fingerprint: Digest::SHA256.hexdigest(result.content.to_s),
      sync_status: :synced,
      last_sync_error_code: nil,
      last_synced_at: Time.current,
      last_sync_attempted_at: Time.current
    )
  end

  def mark_sync_failed(document, error_code)
    document.update!(
      sync_status: :failed,
      last_sync_error_code: error_code,
      last_sync_attempted_at: Time.current
    )
  end

  def with_lock(key, timeout: LOCK_TIMEOUT)
    return unless Redis::Alfred.set(key, job_id, nx: true, ex: timeout.to_i)

    begin
      yield
    ensure
      Redis::Alfred.delete_if_equals(key, job_id)
    end
  end

  def lock_key(document)
    format('CAPTAIN_DOCUMENT_SYNC_LOCK::%d', document.id)
  end
end
