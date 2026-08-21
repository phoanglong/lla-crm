# frozen_string_literal: true

class Captain::Tools::Copilot::GetArticleService < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  def self.name
    'get_article'
  end

  description 'Get details of an article including its content and metadata'
  param :article_id, type: :number, desc: 'The ID of the article to retrieve', required: true

  def execute(article_id:)
    return 'Article not found' unless active?

    id = Integer(article_id, exception: false)
    article = Article.find_by(id: id, account_id: assistant.account_id) if id&.positive?
    article ? bounded_output(article.to_llm_text) : 'Article not found'
  end

  def active?
    user_has_permission('knowledge_base_manage')
  end
end
