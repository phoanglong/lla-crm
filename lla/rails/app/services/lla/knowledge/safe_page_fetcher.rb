# frozen_string_literal: true

class Lla::Knowledge::SafePageFetcher
  Result = Data.define(:url, :title, :description, :favicon_url, :markdown, :links)

  def initialize(account:, url:, capability: :website_analysis)
    @account = account
    @url = Lla::Knowledge::UrlPolicy.canonicalize(url)
    @capability = capability
  end

  def perform
    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: account, provider: :direct_fetch, capability: capability
    )
    crawler = Captain::Tools::SimplePageCrawlService.new(url)
    raise SafeFetch::HttpError, 'website fetch failed' unless crawler.success?

    Result.new(
      url: url,
      title: crawler.page_title,
      description: crawler.meta_description,
      favicon_url: approved_url(crawler.favicon_url),
      markdown: crawler.body_markdown,
      links: crawler.page_links.filter_map { |link| approved_url(link) }
    )
  end

  private

  attr_reader :account, :url, :capability

  def approved_url(candidate)
    return if candidate.blank?
    return unless Lla::Knowledge::UrlPolicy.approved_same_origin?(url, candidate)

    Lla::Knowledge::UrlPolicy.canonicalize(candidate)
  end
end
