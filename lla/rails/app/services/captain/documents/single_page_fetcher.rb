# frozen_string_literal: true

# Tải lại MỘT trang nguồn của tài liệu khi sync — bọc SimplePageCrawlService
# thành kết quả gọn (success/title/content) cho PerformSyncJob.
class Captain::Documents::SinglePageFetcher
  Result = Struct.new(:success, :title, :content, keyword_init: true)

  def initialize(url)
    @url = url
  end

  def fetch
    crawler = Captain::Tools::SimplePageCrawlService.new(@url)
    return Result.new(success: false, title: nil, content: nil) unless crawler.success?

    Result.new(success: true, title: crawler.page_title, content: crawler.body_markdown)
  end
end
