# frozen_string_literal: true

# Nạp tri thức cho một tài liệu mới: PDF thì upload lên OpenAI; web thì crawl
# qua Firecrawl (nếu có key) hoặc crawler đơn giản nội bộ.
class Captain::Documents::CrawlJob < ApplicationJob
  queue_as :low

  DEFAULT_CRAWL_LIMIT = 10
  MAX_CRAWL_LIMIT = 500

  def perform(document)
    return process_pdf(document) if document.pdf_document?

    if firecrawl_api_key.present?
      Captain::Tools::FirecrawlService.new.perform(document.external_link, webhook_url(document), crawl_limit(document.account))
    else
      simple_crawl(document)
    end
  end

  private

  def process_pdf(document)
    Captain::Llm::PdfProcessingService.new(document).process
    document.update!(status: :available)
  end

  # Trần số trang crawl = số tài liệu account còn được tạo (không có hạn mức
  # thì dùng mặc định), chặn trên tuyệt đối để không quét vô hạn.
  def crawl_limit(account)
    available = account.usage_limits.dig(:captain, :documents, :current_available)
    return DEFAULT_CRAWL_LIMIT if available.blank?

    [available, MAX_CRAWL_LIMIT].min
  end

  def webhook_url(document)
    token = Digest::SHA256.hexdigest("#{firecrawl_api_key[-4..]}#{document.assistant_id}#{document.account_id}")
    "#{Rails.application.routes.url_helpers.enterprise_webhooks_firecrawl_url}?assistant_id=#{document.assistant_id}&token=#{token}"
  end

  def simple_crawl(document)
    crawler = Captain::Tools::SimplePageCrawlService.new(document.external_link)
    links = ([document.external_link] + crawler.page_links).uniq

    links.each do |link|
      Captain::Tools::SimplePageCrawlParserJob.perform_later(assistant_id: document.assistant_id, page_link: link)
    end
  end

  def firecrawl_api_key
    @firecrawl_api_key ||= InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY')&.value
  end
end
