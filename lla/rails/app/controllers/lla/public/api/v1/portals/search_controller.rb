# frozen_string_literal: true

module Lla::Public::Api::V1::Portals::SearchController
  private

  def search_articles
    return super unless semantic_search_enabled? && @query.present?

    @articles = @articles.vector_search(
      account_id: @portal.account_id,
      portal_id: @portal.id,
      query: @query,
      locale: search_params[:locale],
      limit: 10,
      requester_key: request.remote_ip
    )
  rescue Lla::Knowledge::ArticleSemanticSearch::Unavailable
    super
  end

  def semantic_search_enabled?
    @portal.account.feature_enabled?('help_center_embedding_search') &&
      Lla::Knowledge::ProviderPolicy.capability_enabled?(:embedding_search)
  end
end
