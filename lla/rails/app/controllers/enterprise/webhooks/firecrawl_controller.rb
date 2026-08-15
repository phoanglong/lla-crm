# frozen_string_literal: true

# Webhook công khai nhận kết quả crawl từ Firecrawl. Xác thực bằng token dẫn
# xuất từ đuôi API key + assistant + account (đúng token CrawlJob đã phát).
# Giữ namespace Enterprise::Webhooks để không đổi URL/route name của CE.
class Enterprise::Webhooks::FirecrawlController < ActionController::API
  def process_payload
    assistant = Captain::Assistant.find_by(id: params[:assistant_id])
    return head :not_found if assistant.blank?
    return head :unauthorized unless valid_token?(assistant)

    enqueue_crawled_pages(assistant) if params[:type] == 'crawl.page'
    head :ok
  end

  private

  def enqueue_crawled_pages(assistant)
    Array(params[:data]).each do |page|
      payload = page.respond_to?(:to_unsafe_h) ? page.to_unsafe_h : page.to_h
      Captain::Tools::FirecrawlParserJob.perform_later(assistant_id: assistant.id, payload: payload.deep_symbolize_keys)
    end
  end

  def valid_token?(assistant)
    api_key = InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY')&.value
    return false if api_key.blank?

    expected = Digest::SHA256.hexdigest("#{api_key[-4..]}#{assistant.id}#{assistant.account_id}")
    ActiveSupport::SecurityUtils.secure_compare(params[:token].to_s, expected)
  end
end
