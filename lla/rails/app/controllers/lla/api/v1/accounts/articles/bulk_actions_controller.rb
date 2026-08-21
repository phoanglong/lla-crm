# frozen_string_literal: true

module Lla::Api::V1::Accounts::Articles::BulkActionsController
  MAX_TRANSLATION_ARTICLES = 25

  def translate
    return unless validate_lla_translate_params?

    duplicates = find_existing_translations
    if duplicates.any? && !force_translation?
      return render json: {
        duplicate_articles: duplicates.map { |article| { id: article.id, title: article.title } }
      }, status: :conflict
    end

    perform_lla_translation
  rescue Lla::Knowledge::ProviderPolicy::Denied
    render json: { error: 'lla_knowledge_provider_disabled' }, status: :unprocessable_entity
  rescue Lla::Knowledge::TranslationOperationService::InvalidRequest,
         Lla::Knowledge::TranslationOperationService::Conflict => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def perform_lla_translation
    operation = Lla::Knowledge::TranslationOperationService.new(
      account: Current.account,
      portal: @portal,
      user: Current.user,
      articles: @articles,
      target_locale: @locale,
      target_category: @category,
      force: force_translation?,
      idempotency_key: request.headers['Idempotency-Key']
    ).perform
    Lla::Knowledge::GenerationOutboxDispatchJob.perform_later(operation.id)
    response.set_header('X-LLA-Knowledge-Operation-Id', operation.id.to_s)
    head :ok
  end

  def lla_translate_params
    params.permit(:locale, :category_id, :force, ids: [])
  end

  def validate_lla_translate_params?
    @locale = lla_translate_params[:locale].to_s
    @category = @portal.categories.find_by(id: lla_translate_params[:category_id], locale: @locale)
    ids = Array(lla_translate_params[:ids]).map(&:to_i).uniq
    @articles = @portal.articles.where(id: ids)

    lla_translation_authorized? && captain_available? && valid_translation_locale? &&
      valid_translation_category? && valid_translation_articles?(ids)
  end

  def lla_translation_authorized?
    membership = AccountUser.find_by(account_id: Current.account.id, user_id: Current.user.id)
    return true if membership&.administrator?

    head :forbidden
    false
  end

  def captain_available?
    return true if Current.account.feature_enabled?('captain_tasks')

    render_could_not_create_error(I18n.t('portals.articles.captain_not_available'))
    false
  end

  def valid_translation_locale?
    return true if @portal.config['allowed_locales']&.include?(@locale)

    render_could_not_create_error(I18n.t('portals.articles.locale_not_available'))
    false
  end

  def valid_translation_category?
    return true if lla_translate_params[:category_id].blank? || @category.present?

    render_could_not_create_error(I18n.t('portals.articles.category_not_found'))
    false
  end

  def valid_translation_articles?(ids)
    return true if ids.size.between?(1, MAX_TRANSLATION_ARTICLES) && @articles.size == ids.size &&
                   @articles.none? { |article| article.locale == @locale }

    render_could_not_create_error(I18n.t('portals.articles.no_articles_found'))
    false
  end

  def find_existing_translations
    root_ids = @articles.map { |article| Article.find_root_article_id(article) }
    @portal.articles.where(associated_article_id: root_ids, locale: @locale)
  end

  def force_translation?
    ActiveModel::Type::Boolean.new.cast(lla_translate_params[:force])
  end
end
