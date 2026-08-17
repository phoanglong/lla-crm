# frozen_string_literal: true

class PageCrawlerService
  def initialize(external_link, account:)
    @result = Lla::Knowledge::SafePageFetcher.new(
      account: account, url: external_link, capability: :external_crawl
    ).perform
  end

  def page_links
    result.links.to_set
  end

  def page_title
    result.title
  end

  def body_text_content
    result.markdown
  end

  private

  attr_reader :result
end
