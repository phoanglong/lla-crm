# frozen_string_literal: true

# Nhận từng trang Firecrawl trả về qua webhook và ghi thành tài liệu tri thức
# (upsert theo external_link đã chuẩn hoá).
class Captain::Tools::FirecrawlParserJob < ApplicationJob
  class PermanentPayloadError < StandardError; end

  queue_as :low
  discard_on PermanentPayloadError

  NAME_LIMIT = 255
  CONTENT_LIMIT = 15_000

  def perform(assistant_id:, payload:)
    assistant = Captain::Assistant.find(assistant_id)
    data = payload.with_indifferent_access
    metadata = data[:metadata] || {}

    document = assistant.documents.find_or_initialize_by(external_link: canonical_url(metadata))
    document.assign_attributes(
      name: metadata[:title].to_s.truncate(NAME_LIMIT),
      content: data[:markdown].to_s.truncate(CONTENT_LIMIT),
      status: :available,
      sync_status: :synced,
      last_synced_at: Time.current,
      last_sync_attempted_at: Time.current
    )
    document.save!
  rescue PermanentPayloadError
    raise
  rescue StandardError => e
    raise "Failed to parse FireCrawl data: #{e.message}"
  end

  private

  # Firecrawl có thể trả cả sourceURL (trang gốc) lẫn url (canonical) — ưu tiên
  # sourceURL; bỏ dấu / cuối để khớp khoá duy nhất của tài liệu.
  def canonical_url(metadata)
    raw_url = metadata[:sourceURL].presence || metadata[:url]
    validated = Lla::Network::UrlSafety.validate!(raw_url)
    validated.uri.to_s.delete_suffix('/')
  rescue Lla::Network::UrlSafety::UnsafeUrlError => e
    raise PermanentPayloadError, e.message
  end
end
