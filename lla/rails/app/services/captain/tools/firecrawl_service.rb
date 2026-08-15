# frozen_string_literal: true

# Gọi Firecrawl (v2) crawl cả website; kết quả trả về bất đồng bộ qua webhook
# enterprise/webhooks/firecrawl. Key lấy từ InstallationConfig.
class Captain::Tools::FirecrawlService
  API_ENDPOINT = 'https://api.firecrawl.dev/v2/crawl'
  DEFAULT_CRAWL_LIMIT = 10
  MAX_DISCOVERY_DEPTH = 50

  # Phần tử trang không mang nội dung tri thức — loại trước khi trích markdown.
  FIRECRAWL_EXCLUDE_TAGS = %w[nav footer aside header script style noscript form iframe svg].freeze

  def initialize
    @api_key = InstallationConfig.find_by!(name: 'CAPTAIN_FIRECRAWL_API_KEY').value
    raise 'Missing API key' if @api_key.blank?
  end

  def perform(url, webhook_url, crawl_limit = DEFAULT_CRAWL_LIMIT)
    HTTParty.post(
      API_ENDPOINT,
      headers: { 'Authorization' => "Bearer #{@api_key}", 'Content-Type' => 'application/json' },
      body: crawl_payload(url, webhook_url, crawl_limit).to_json
    )
  rescue StandardError => e
    raise "Failed to crawl URL: #{e.message}"
  end

  private

  def crawl_payload(url, webhook_url, crawl_limit)
    {
      url: url,
      maxDiscoveryDepth: MAX_DISCOVERY_DEPTH,
      sitemap: 'include',
      limit: crawl_limit,
      webhook: { url: webhook_url },
      scrapeOptions: {
        onlyMainContent: true,
        formats: ['markdown'],
        excludeTags: FIRECRAWL_EXCLUDE_TAGS,
        maxAge: 0
      }
    }
  end
end
