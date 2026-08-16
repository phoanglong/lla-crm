# frozen_string_literal: true

class Captain::Tools::Copilot::SearchArticlesService < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  def self.name
    'search_articles'
  end

  description 'Search articles based on parameters'
  param :query, desc: 'Search articles by title or content (partial match)', required: false
  param :category_id, type: :number, desc: 'Filter articles by category ID', required: false
  param :status, type: :string, desc: 'Filter articles by status - draft, published, archived', required: false

  def execute(query: nil, category_id: nil, status: nil)
    return 'No articles found' unless active?
    return 'Please provide an article search filter' unless meaningful_filter?(query, category_id, status)
    return 'Invalid article status' if status.present? && !Article.statuses.key?(status.to_s)

    articles = fetch_articles(query: bounded_query(query), category_id: category_id, status: status)
    results = articles.limit(MAX_RESULT_COUNT).to_a
    return 'No articles found' if results.empty?

    bounded_output("Total number of articles: #{results.length}\n#{results.map(&:to_llm_text).join("\n---\n")}")
  end

  def active?
    user_has_permission('knowledge_base_manage')
  end

  private

  def meaningful_filter?(query, category_id, status)
    meaningful_query?(query) || Integer(category_id, exception: false)&.positive? || status.present?
  end

  def fetch_articles(query:, category_id:, status:)
    articles = Article.where(account_id: assistant.account_id)
    if meaningful_query?(query)
      escaped_query = ActiveRecord::Base.sanitize_sql_like(query)
      articles = articles.where('title ILIKE :query OR content ILIKE :query', query: "%#{escaped_query}%")
    end
    parsed_category_id = Integer(category_id, exception: false)
    articles = articles.where(category_id: parsed_category_id) if parsed_category_id&.positive?
    articles = articles.where(status: status) if status.present?
    articles.order(updated_at: :desc, id: :desc)
  end
end
