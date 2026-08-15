# frozen_string_literal: true

# Nhận từng trang Firecrawl trả về qua webhook và ghi thành tài liệu tri thức
# (upsert theo external_link đã chuẩn hoá).
class Captain::Tools::FirecrawlParserJob < ApplicationJob
  queue_as :low

  def perform(assistant_id:, payload:)
    assistant = Captain::Assistant.find(assistant_id)
    data = payload.with_indifferent_access
    metadata = data[:metadata] || {}

    document = assistant.documents.find_or_initialize_by(external_link: canonical_url(metadata))
    document.assign_attributes(
      name: metadata[:title],
      content: data[:markdown],
      status: :available,
      sync_status: :synced,
      last_synced_at: Time.current,
      last_sync_attempted_at: Time.current
    )
    document.save!
  rescue StandardError => e
    raise "Failed to parse FireCrawl data: #{e.message}"
  end

  private

  # Firecrawl có thể trả cả sourceURL (trang gốc) lẫn url (canonical) — ưu tiên
  # sourceURL; bỏ dấu / cuối để khớp khoá duy nhất của tài liệu.
  def canonical_url(metadata)
    (metadata[:sourceURL].presence || metadata[:url]).to_s.delete_suffix('/')
  end
end
