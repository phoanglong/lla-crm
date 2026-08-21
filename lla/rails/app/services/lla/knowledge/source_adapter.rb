# frozen_string_literal: true

# Provider-neutral, tenant-consented source discovery/scrape adapter. Firecrawl
# is optional; the existing DNS-pinned local fetcher is the bounded fallback.
class Lla::Knowledge::SourceAdapter
  class Unavailable < StandardError; end

  Link = Data.define(:url, :title, :description)
  Page = Data.define(:url, :markdown, :page_title)
  FIRECRAWL_KEY = 'CAPTAIN_FIRECRAWL_API_KEY'
  MAX_PAGE_MARKDOWN = 60_000

  def initialize(account:, operation:, capability:)
    @account = account
    @operation = operation
    @capability = capability
    @origin = canonical_source(operation.portal.homepage_link)
  end

  def discover(url, limit:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    raise Unavailable, 'lla_knowledge_source_origin_rejected' unless Lla::Knowledge::UrlPolicy.approved_same_origin?(origin, url)

    links = firecrawl_available? ? discover_with_firecrawl(limit) : discover_direct
    links.filter_map { |link| normalize_link(link) }.uniq(&:url).first(limit)
  rescue Firecrawl::FirecrawlError => e
    raise Unavailable, stable_error(e) unless direct_available?

    discover_direct.filter_map { |link| normalize_link(link) }.uniq(&:url).first(limit)
  end # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def fetch_pages(urls) # rubocop:disable Metrics/CyclomaticComplexity
    normalized = Array(urls).first(3).map { |url| approved_source!(url) }
    raise Unavailable, 'lla_knowledge_sources_empty' if normalized.empty?

    pages = firecrawl_available? ? scrape_with_firecrawl(normalized) : scrape_direct(normalized)
    pages.filter_map { |page| normalize_page(page) }
  rescue Firecrawl::FirecrawlError => e
    raise Unavailable, stable_error(e) unless direct_available?

    scrape_direct(normalized).filter_map { |page| normalize_page(page) }
  end # rubocop:enable Metrics/CyclomaticComplexity

  private

  attr_reader :account, :operation, :capability, :origin

  def firecrawl_available?
    firecrawl_key.present? && Lla::Knowledge::ProviderPolicy.egress_permitted?(
      account: account, provider: :firecrawl, capability: capability
    )
  end

  def direct_available?
    Lla::Knowledge::ProviderPolicy.egress_permitted?(
      account: account, provider: :direct_fetch, capability: capability
    )
  end

  def discover_with_firecrawl(limit)
    record_provider_consent!(:firecrawl)
    data = firecrawl_client.map(
      origin,
      Firecrawl::Models::MapOptions.new(limit: limit, search: Onboarding::HelpCenterCurator::MAP_SEARCH)
    )
    Array(data.links)
  end

  def discover_direct
    authorize_direct!
    page = safe_fetch(origin)
    [
      { url: page.url, title: page.title, description: page.description },
      *page.links.map { |url| { url: url, title: nil, description: nil } }
    ]
  end

  def scrape_with_firecrawl(urls)
    record_provider_consent!(:firecrawl)
    result = firecrawl_client.batch_scrape(
      urls,
      Firecrawl::Models::BatchScrapeOptions.new(options: firecrawl_scrape_options)
    )
    Array(result.data).map do |document|
      metadata = document&.metadata || {}
      {
        url: metadata['sourceURL'] || metadata['url'],
        markdown: document&.markdown,
        page_title: metadata['title']
      }
    end
  end

  def scrape_direct(urls)
    authorize_direct!
    urls.map do |url|
      page = safe_fetch(url)
      { url: page.url, markdown: page.markdown, page_title: page.title }
    end
  end

  def safe_fetch(url)
    Lla::Knowledge::SafePageFetcher.new(account: account, url: url, capability: capability).perform
  end

  def authorize_direct!
    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: account, provider: :direct_fetch, capability: capability
    )
    record_provider_consent!(:direct_fetch)
  end

  def normalize_link(link)
    data = link.is_a?(Hash) ? link.deep_symbolize_keys : { url: link.to_s }
    url = approved_source!(data[:url])
    Link.new(url: url, title: bounded(data[:title], 200), description: bounded(data[:description], 500))
  rescue Lla::Knowledge::UrlPolicy::InvalidUrl, Unavailable
    nil
  end

  def normalize_page(page)
    data = page.is_a?(Hash) ? page.deep_symbolize_keys : page.to_h.deep_symbolize_keys
    markdown = data[:markdown].to_s.strip.first(MAX_PAGE_MARKDOWN)
    return if markdown.blank?

    Page.new(url: approved_source!(data[:url]), markdown: markdown, page_title: bounded(data[:page_title], 200))
  rescue Lla::Knowledge::UrlPolicy::InvalidUrl, Unavailable
    nil
  end

  def approved_source!(candidate)
    value = canonical_source(candidate)
    raise Unavailable, 'lla_knowledge_source_origin_rejected' unless Lla::Knowledge::UrlPolicy.approved_same_origin?(origin, value)

    value
  end

  def canonical_source(value)
    Lla::Knowledge::UrlPolicy.canonical_source(value)
  end

  def bounded(value, length)
    value.to_s.squish.first(length)
  end

  def firecrawl_client
    @firecrawl_client ||= Firecrawl::Client.new(api_key: firecrawl_key)
  end

  def firecrawl_key
    @firecrawl_key ||= InstallationConfig.find_by(name: FIRECRAWL_KEY)&.value.to_s.presence
  end

  def firecrawl_scrape_options
    Firecrawl::Models::ScrapeOptions.new(
      formats: ['markdown'],
      only_main_content: true,
      exclude_tags: %w[iframe .sidebar .cookie-banner [role=navigation] [role=banner] [role=contentinfo]],
      max_age: 7.days.in_milliseconds
    )
  end

  def record_provider_consent!(provider)
    digest = Lla::Knowledge::ProviderPolicy.consent_digest(account, provider)
    raise Lla::Knowledge::ProviderPolicy::Denied if digest.blank?

    operation.with_lock do
      operation.update!(provider_consent_digests: operation.provider_consent_digests.merge(provider.to_s => digest))
    end
  end

  def stable_error(error)
    "lla_knowledge_source_#{error.class.name.demodulize.underscore}"
  end
end
