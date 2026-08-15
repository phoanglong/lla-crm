# frozen_string_literal: true

# Crawl một liên kết đã phát hiện và ghi thành tài liệu tri thức. Trang không
# tồn tại (404) là lỗi vĩnh viễn — bỏ, không retry.
class Captain::Tools::SimplePageCrawlParserJob < ApplicationJob
  class PermanentCrawlError < StandardError; end

  queue_as :low
  discard_on PermanentCrawlError

  NAME_LIMIT = 255
  CONTENT_LIMIT = 15_000
  PERMANENT_STATUS_CODES = [404, 410].freeze

  def perform(assistant_id:, page_link:)
    assistant = Captain::Assistant.find(assistant_id)
    crawler = Captain::Tools::SimplePageCrawlService.new(page_link)

    handle_fetch_failure(assistant, page_link, crawler) unless crawler.success?

    upsert_document(assistant, page_link, crawler)
  rescue PermanentCrawlError
    raise
  rescue StandardError => e
    raise "Failed to parse data: #{page_link} #{e.message}"
  end

  private

  def upsert_document(assistant, page_link, crawler)
    document = assistant.documents.find_or_initialize_by(external_link: canonical_link(page_link))
    document.assign_attributes(
      name: crawler.page_title.to_s.truncate(NAME_LIMIT),
      content: crawler.body_markdown.to_s.truncate(CONTENT_LIMIT),
      status: :available,
      sync_status: :synced,
      last_sync_error_code: nil,
      last_synced_at: Time.current,
      last_sync_attempted_at: Time.current
    )
    document.save!
  end

  # Trang hỏng: chỉ đánh dấu tài liệu ĐÃ tồn tại (không tạo bản ghi cho liên kết
  # chưa từng lưu), rồi ném lỗi tương ứng.
  def handle_fetch_failure(assistant, page_link, crawler)
    permanent = PERMANENT_STATUS_CODES.include?(crawler.status_code)
    mark_existing_document_failed(assistant, page_link, permanent ? 'not_found' : 'fetch_failed')

    raise PermanentCrawlError, "Page not found: #{page_link}" if permanent

    raise "Failed to fetch page: #{page_link}"
  end

  def mark_existing_document_failed(assistant, page_link, error_code)
    document = assistant.documents.find_by(external_link: canonical_link(page_link))
    return if document.blank?

    document.update!(
      status: :available,
      sync_status: :failed,
      last_sync_error_code: error_code,
      last_sync_attempted_at: Time.current
    )
  end

  def canonical_link(page_link)
    page_link.to_s.delete_suffix('/')
  end
end
