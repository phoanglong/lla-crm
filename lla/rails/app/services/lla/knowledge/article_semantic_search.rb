# frozen_string_literal: true

class Lla::Knowledge::ArticleSemanticSearch
  class Unavailable < StandardError; end

  MAX_QUERY_BYTES = 512
  MAX_RESULTS = 20
  MAX_CANDIDATES = 50
  DEFAULT_RESULTS = 5
  DISTANCE_THRESHOLD = 0.35

  def initialize(scope:, portal:, query:, filters:, requester_key:)
    @scope = scope
    @portal = portal
    @query = query.to_s.scrub.squish
    @filters = filters.to_h.symbolize_keys
    @requester_key = requester_key
  end

  def perform
    validate!
    authorize!
    embedding = Captain::Llm::EmbeddingService.new(account_id: portal.account_id).get_embedding(query)
    article_ids = nearest_article_ids(embedding)
    ordered_articles(article_ids)
  rescue Lla::Knowledge::ProviderPolicy::Denied, Captain::Llm::EmbeddingService::UnsupportedModel,
         Captain::Llm::EmbeddingService::InvalidEmbedding => e
    raise Unavailable, e.class.name
  rescue Unavailable
    raise
  rescue StandardError => e
    Rails.logger.warn("LLA semantic search unavailable portal_id=#{portal.id} error=#{e.class.name}")
    raise Unavailable, e.class.name
  end

  private

  attr_reader :scope, :portal, :query, :filters, :requester_key

  def validate!
    raise Unavailable, 'query_invalid' if query.blank? || query.bytesize > MAX_QUERY_BYTES
    raise Unavailable, 'rate_limited' unless Lla::Knowledge::PublicSearchRateLimiter.allowed?(
      portal: portal, requester_key: requester_key
    )
  end

  def authorize!
    raise Lla::Knowledge::ProviderPolicy::Denied unless portal.account.feature_enabled?('help_center_embedding_search')

    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: portal.account, provider: :openai, capability: :embedding_search
    )
  end

  def nearest_article_ids(embedding)
    profile = Captain::Llm::EmbeddingService.embedding_profile
    candidates = ArticleEmbedding.active
                                 .for_profile(profile.fetch(:model), profile.fetch(:dimensions))
                                 .where(account_id: portal.account_id, portal_id: portal.id)
                                 .where(article_id: filtered_scope.select(:id))
                                 .nearest_neighbors(:embedding, embedding, distance: 'cosine')
                                 .limit(MAX_CANDIDATES)
                                 .to_a
    candidates.select { |candidate| candidate.neighbor_distance <= DISTANCE_THRESHOLD }
              .map(&:article_id).uniq.first(result_limit)
  end

  def ordered_articles(article_ids)
    return filtered_scope.none if article_ids.empty?

    filtered_scope.where(id: article_ids).in_order_of(:id, article_ids)
  end

  def filtered_scope
    @filtered_scope ||= scope.where(
      account_id: portal.account_id,
      portal_id: portal.id,
      status: Article.statuses.fetch('published')
    ).then { |relation| apply_filters(relation) }
  end

  def apply_filters(relation)
    relation = relation.where(locale: filters[:locale]) if filters[:locale].present?
    relation = relation.where(author_id: filters[:author_id]) if filters[:author_id].present?
    relation = relation.joins(:category).where(categories: { slug: filters[:category_slug] }) if filters[:category_slug].present?
    relation
  end

  def result_limit
    value = filters.key?(:limit) ? filters[:limit].to_i : DEFAULT_RESULTS
    value.clamp(1, MAX_RESULTS)
  end
end
