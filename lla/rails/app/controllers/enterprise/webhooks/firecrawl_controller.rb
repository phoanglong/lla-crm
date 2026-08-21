# frozen_string_literal: true

# Webhook công khai nhận kết quả crawl từ Firecrawl. Xác thực bằng token ký,
# có hạn dùng và ràng buộc assistant/account do CrawlJob phát.
# Giữ namespace Enterprise::Webhooks để không đổi URL/route name của CE.
class Enterprise::Webhooks::FirecrawlController < ActionController::API
  MAX_PAGES_PER_REQUEST = 100
  MAX_PAGE_PAYLOAD_BYTES = 1.megabyte

  def process_payload
    assistant = Captain::Assistant.find_by(id: params[:assistant_id])
    return head :unauthorized if assistant.blank? || !valid_token?(assistant)

    if params[:type] == 'crawl.page'
      pages = permitted_pages
      return head :content_too_large if pages.nil?

      enqueue_crawled_pages(assistant, pages)
    end
    head :ok
  end

  private

  def enqueue_crawled_pages(assistant, pages)
    pages.each do |payload|
      Captain::Tools::FirecrawlParserJob.perform_later(assistant_id: assistant.id, payload: payload)
    end
  end

  def valid_token?(assistant)
    Lla::Captain::FirecrawlWebhookToken.valid?(params[:token], assistant)
  end

  def permitted_pages
    raw_pages = Array(params[:data])
    return if raw_pages.length > MAX_PAGES_PER_REQUEST
    return unless raw_pages.all? { |raw_page| page_payload?(raw_page) }

    pages = raw_pages.map { |raw_page| permit_page(raw_page) }
    return if pages.sum { |page| page.to_json.bytesize } > MAX_PAGE_PAYLOAD_BYTES

    pages
  end

  def page_payload?(raw_page)
    raw_page.is_a?(ActionController::Parameters) || raw_page.is_a?(Hash)
  end

  def permit_page(raw_page)
    page_params = raw_page.respond_to?(:permit) ? raw_page : ActionController::Parameters.new(raw_page)
    page_params.permit(:markdown, metadata: %i[sourceURL url title]).to_h.deep_symbolize_keys
  end
end
