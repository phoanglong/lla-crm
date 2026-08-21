# frozen_string_literal: true

class Onboarding::HelpCenterCurator
  MAP_SEARCH = 'docs help support faq resources guides kb knowledge articles handbook learn tutorial troubleshooting'
  MIN_ARTICLES = 1

  Skipped = Onboarding::HelpCenterErrors::CurationSkipped

  def initialize(account:, operation:)
    @account = account
    @operation = operation
  end

  def perform # rubocop:disable Metrics/AbcSize
    raise Skipped, 'lla_knowledge_website_missing' if website_url.blank?

    links = source_adapter.discover(website_url, limit: operation.max_source_urls)
    raise Skipped, 'lla_knowledge_links_empty' if links.empty?

    response = Captain::Llm::HelpCenterCurationService.new(
      account: account, links: links, operation: operation
    ).with_quota_idempotency_key("knowledge-operation:#{operation.id}:curation").perform
    raise Skipped, 'lla_knowledge_curation_failed' if response[:error]

    plan = enforce_provenance(response[:message], links)
    raise Skipped, 'lla_knowledge_plan_below_minimum' if plan[:articles].size < MIN_ARTICLES

    plan.deep_stringify_keys
  rescue Lla::Knowledge::SourceAdapter::Unavailable => e
    raise Skipped, e.message
  end # rubocop:enable Metrics/AbcSize

  private

  attr_reader :account, :operation

  def website_url
    operation.portal.homepage_link.presence
  end

  def source_adapter
    @source_adapter ||= Lla::Knowledge::SourceAdapter.new(
      account: account, operation: operation, capability: :external_crawl
    )
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def enforce_provenance(message, links)
    data = message.is_a?(Hash) ? message.deep_symbolize_keys : {}
    allowed_urls = links.to_set(&:url)
    categories = Array(data[:categories]).first(10)
    category_names = categories.map { |category| category[:name].to_s }
    articles = Array(data[:articles]).first(operation.max_items).filter_map do |article|
      category_name = article[:category_name].to_s
      next unless category_names.include?(category_name)

      urls = Array(article[:urls]).filter_map { |url| canonical_source(url) }
                                  .select { |url| allowed_urls.include?(url) }.uniq.first(3)
      next if urls.empty?

      article.merge(urls: urls)
    end
    used_names = articles.to_set { |article| article[:category_name].to_s }

    {
      categories: categories.select { |category| used_names.include?(category[:name].to_s) },
      articles: articles,
      allowed_urls: allowed_urls.to_a
    }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def canonical_source(value)
    Lla::Knowledge::UrlPolicy.canonical_source(value)
  rescue Lla::Knowledge::UrlPolicy::InvalidUrl
    nil
  end
end
