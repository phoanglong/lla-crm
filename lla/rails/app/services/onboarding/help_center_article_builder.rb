# frozen_string_literal: true

class Onboarding::HelpCenterArticleBuilder
  BuildFailed = Onboarding::HelpCenterErrors::ArticleBuildFailed

  def initialize(account:, portal:, user:, operation:, item:, article:) # rubocop:disable Metrics/ParameterLists
    @account = account
    @portal = portal
    @user = user
    @operation = operation
    @item = item
    spec = article.is_a?(Hash) ? article.deep_symbolize_keys : {}
    @urls = Array(spec[:urls]).filter_map { |url| canonical_source(url) }.uniq.first(3)
    @title = spec[:title].to_s.first(80)
  end # rubocop:enable Metrics/ParameterLists

  def perform # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    validate_tenant!
    raise BuildFailed, 'lla_knowledge_sources_empty' if urls.empty?

    source_pages = source_adapter.fetch_pages(urls)
    raise BuildFailed, 'lla_knowledge_sources_unusable' if source_pages.empty?

    response = Captain::Llm::ArticleWriterService.new(
      account: account,
      source_pages: source_pages,
      operation: operation,
      item: item,
      hint_title: title.presence || source_pages.first.page_title
    ).with_quota_idempotency_key("knowledge-item:#{item.id}:writer").perform
    raise BuildFailed, 'lla_knowledge_writer_failed' if response[:error]

    payload = Lla::Knowledge::GeneratedArticleSanitizer.call(response[:message])
    raise BuildFailed, 'lla_knowledge_writer_title_blank' if payload[:title].blank?
    raise BuildFailed, 'lla_knowledge_writer_content_blank' if payload[:content].blank?

    payload.merge(meta: { source_urls: source_pages.map(&:url) })
  rescue Lla::Knowledge::SourceAdapter::Unavailable => e
    raise BuildFailed, e.message
  end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  private

  attr_reader :account, :portal, :user, :operation, :item, :urls, :title

  def validate_tenant! # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    valid = portal.account_id == account.id && operation.account_id == account.id && operation.portal_id == portal.id &&
            item.account_id == account.id && item.portal_id == portal.id && item.operation.id == operation.id &&
            item.category&.account_id == account.id && item.category&.portal_id == portal.id &&
            AccountUser.exists?(account_id: account.id, user_id: user.id)
    raise BuildFailed, 'lla_knowledge_tenant_mismatch' unless valid
  end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def source_adapter
    @source_adapter ||= Lla::Knowledge::SourceAdapter.new(
      account: account, operation: operation, capability: :article_generation
    )
  end

  def canonical_source(value)
    url = Lla::Knowledge::UrlPolicy.canonical_source(value)
    return url if Lla::Knowledge::UrlPolicy.approved_same_origin?(portal.homepage_link, url)
  rescue Lla::Knowledge::UrlPolicy::InvalidUrl
    nil
  end
end
