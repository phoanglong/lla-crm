# frozen_string_literal: true

module Lla::Public::Api::V1::Portals::ArticlesController
  private

  def search_articles
    return super unless semantic_search_enabled? && list_params[:query].present?

    @articles = @articles.vector_search(
      account_id: @portal.account_id,
      portal_id: @portal.id,
      query: list_params[:query],
      locale: list_params[:locale],
      category_slug: permitted_params[:category_slug],
      limit: list_params[:per_page],
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
