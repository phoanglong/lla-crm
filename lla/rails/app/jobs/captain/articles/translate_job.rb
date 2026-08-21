# frozen_string_literal: true

class Captain::Articles::TranslateJob < ApplicationJob
  class InvalidTranslation < StandardError; end

  queue_as :low

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.send(:terminal_failure, error)
  end

  def perform(reference, article_id = nil, target_locale = nil, target_category_id = nil, user = nil) # rubocop:disable Metrics/ParameterLists
    return schedule_legacy(reference, article_id, target_locale, target_category_id, user) if reference.is_a?(Account)

    perform_outbox(reference)
  end

  private

  def perform_outbox(outbox_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    outbox = Lla::Knowledge::GenerationOutbox.find(outbox_id)
    raise ArgumentError, 'invalid translation outbox event' unless outbox.event_type == 'translate_article'

    operation = outbox.operation
    payload = outbox.payload
    item = operation.items.find(payload.fetch(:generation_item_id))
    token = SecureRandom.uuid
    claimed = Lla::Knowledge::GenerationStateService.new(operation).claim_item!(item.id, token: token)
    return if claimed.blank?

    source, category = validated_context(operation, payload, claimed)
    translated = translate_article(operation, claimed, source, payload.fetch(:target_locale))
    attributes = Lla::Knowledge::TranslatedArticleSanitizer.call(**translated)
    raise InvalidTranslation, 'translated article is empty' if attributes[:title].blank? || attributes[:content].blank?

    Lla::Knowledge::GenerationStateService.new(operation).complete_translation_item!(
      item.id,
      token: token,
      source_article_id: source.id,
      target_locale: payload.fetch(:target_locale),
      target_category_id: category&.id,
      force: payload.fetch(:force),
      article_attributes: attributes
    )
  rescue Lla::Knowledge::PayloadCipher::InvalidPayload
    terminalize_invalid_payload(operation || outbox&.operation)
  rescue Lla::Knowledge::ProviderPolicy::Denied, Lla::Knowledge::GenerationStateService::TranslationConflict,
         Lla::Knowledge::GenerationStateService::StaleSource, InvalidTranslation => e
    fail_item(operation, item, token, "translation_#{e.class.name.demodulize.underscore}")
  rescue StandardError => e
    release_item(operation, item, token, e)
    raise
  end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def schedule_legacy(account, article_id, target_locale, target_category_id, user)
    article = account.articles.find(article_id)
    category = article.portal.categories.find_by(id: target_category_id, locale: target_locale)
    operation = Lla::Knowledge::TranslationOperationService.new(
      account: account,
      portal: article.portal,
      user: user,
      articles: [article],
      target_locale: target_locale,
      target_category: category,
      force: true
    ).perform
    Lla::Knowledge::GenerationOutboxDispatchJob.perform_later(operation.id)
  end

  def validated_context(operation, payload, item) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    raise InvalidTranslation, 'operation type is invalid' unless operation.operation_type == 'translation' && item.item_type == 'translation'

    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: operation.account, provider: :openai, capability: :article_translation
    )
    membership = AccountUser.find_by(account_id: operation.account_id, user_id: operation.user_id)
    raise InvalidTranslation, 'translation actor is not authorized' unless membership&.administrator?

    source = operation.portal.articles.find(payload.fetch(:source_article_id))
    raise InvalidTranslation, 'translation source root is invalid' unless Article.find_root_article_id(source) == payload.fetch(:root_article_id).to_i
    raise Lla::Knowledge::GenerationStateService::StaleSource unless Lla::Knowledge::ArticleSearchDocument.digest(source) == item.source_digest

    locale = payload.fetch(:target_locale).to_s
    raise InvalidTranslation, 'translation locale is unavailable' unless Array(operation.portal.config['allowed_locales']).include?(locale)
    raise InvalidTranslation, 'translation locale matches source' if source.locale == locale

    category_id = payload[:target_category_id]
    category = operation.portal.categories.find_by(id: category_id, locale: locale) if category_id.present?
    raise InvalidTranslation, 'translation category is invalid' if category_id.present? && category.blank?

    [source, category]
  end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def translate_article(operation, item, source, target_locale)
    target_language = language_name_for(target_locale)
    {
      title: translate_field(operation, item, source.title, target_language, :title),
      description: translate_optional_field(operation, item, source.description, target_language, :description),
      content: translate_field(operation, item, source.content, target_language, :content)
    }
  end

  def translate_optional_field(operation, item, text, language, type)
    return if text.blank?

    translate_field(operation, item, text, language, type)
  end

  def translate_field(operation, item, text, language, type)
    service = Captain::Llm::ArticleTranslationService.new(
      account: operation.account,
      operation: operation,
      text: text,
      target_language: language,
      type: type
    ).with_quota_idempotency_key(
      "translation:#{operation.id}:#{item.id}:#{item.attempts}:#{type}"
    )
    response = service.perform
    raise InvalidTranslation, response[:code].to_s.presence || 'provider_error' if response[:error]

    response[:message]
  end

  def language_name_for(locale_code)
    @language_map ||= YAML.safe_load_file(
      Rails.root.join('config/languages/language_map.yml'), permitted_classes: [], aliases: false
    )
    @language_map[locale_code] || locale_code
  end

  def release_item(operation, item, token, error)
    return if operation.blank? || item.blank? || token.blank?

    Lla::Knowledge::GenerationStateService.new(operation).release_item!(
      item.id, token: token, error_code: "translation_#{error.class.name.demodulize.underscore}"
    )
  rescue Lla::Knowledge::GenerationStateService::InvalidClaim
    nil
  end

  def fail_item(operation, item, token, code)
    return if operation.blank? || item.blank?

    Lla::Knowledge::GenerationStateService.new(operation).fail_item!(
      item.id, token: token, error_code: code
    )
  end

  def terminal_failure(error)
    outbox = Lla::Knowledge::GenerationOutbox.find_by(id: arguments.first)
    return if outbox.blank?

    item_id = outbox.payload[:generation_item_id]
    Lla::Knowledge::GenerationStateService.new(outbox.operation).fail_item!(
      item_id, error_code: "translation_#{error.class.name.demodulize.underscore}"
    )
  rescue Lla::Knowledge::PayloadCipher::InvalidPayload
    terminalize_invalid_payload(outbox&.operation)
  rescue ArgumentError, ActiveRecord::RecordNotFound
    nil
  end

  def terminalize_invalid_payload(operation)
    return if operation.blank?

    Lla::Knowledge::GenerationStateService.new(operation).terminalize!(
      state: 'failed', error_code: 'translation_payload_invalid'
    )
  end
end
