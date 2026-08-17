# frozen_string_literal: true

class Lla::Knowledge::TranslationOperationService
  class InvalidRequest < StandardError; end
  class Conflict < StandardError; end

  MAX_ARTICLES = 25
  IDEMPOTENCY_PATTERN = /\A[a-zA-Z0-9_.:-]{8,128}\z/

  # rubocop:disable Metrics/ParameterLists
  def initialize(account:, portal:, user:, articles:, target_locale:, target_category:, force:, idempotency_key: nil)
    @account = account
    @portal = portal
    @user = user
    @articles = Array(articles).uniq(&:id)
    @target_locale = target_locale.to_s
    @target_category = target_category
    @force = ActiveModel::Type::Boolean.new.cast(force)
    @idempotency_key = idempotency_key.to_s.presence
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    validate!
    authorize!
    Lla::Knowledge::GenerationOperation.transaction(requires_new: true) do
      operation = create_or_find_operation
      verify_operation!(operation)
      persist_items_and_outboxes!(operation)
      operation
    end
  end

  private

  attr_reader :account, :portal, :user, :articles, :target_locale, :target_category, :force, :idempotency_key

  def validate! # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    raise InvalidRequest, 'translation article count is invalid' unless articles.size.between?(1, MAX_ARTICLES)
    raise InvalidRequest, 'portal must belong to account' unless portal&.account_id == account&.id
    raise InvalidRequest, 'translation user must be an administrator' unless account_user&.administrator?
    raise InvalidRequest, 'translation locale is unavailable' unless Array(portal.config['allowed_locales']).include?(target_locale)
    raise InvalidRequest, 'translation source locale matches target' if articles.any? { |article| article.locale == target_locale }
    unless articles.all? { |article| article.persisted? && [article.account_id, article.portal_id] == [account.id, portal.id] }
      raise InvalidRequest, 'translation articles must share the operation tenant and portal'
    end
    if target_category && [target_category.account_id, target_category.portal_id, target_category.locale] != [account.id, portal.id, target_locale]
      raise InvalidRequest, 'translation category is invalid'
    end
    return unless idempotency_key && !IDEMPOTENCY_PATTERN.match?(idempotency_key)

    raise InvalidRequest, 'translation idempotency key is invalid'
  end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def authorize!
    raise InvalidRequest, 'captain is unavailable' unless account.feature_enabled?('captain_tasks')

    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: account, provider: :openai, capability: :article_translation
    )
  end

  def create_or_find_operation
    Lla::Knowledge::GenerationOperation.create_or_find_by!(
      account: account, portal: portal, idempotency_digest: idempotency_digest
    ) do |operation|
      operation.user = user
      operation.operation_type = 'translation'
      operation.state = 'dispatching'
      operation.request_digest = request_digest
      operation.consent_digest = consent_digest
      operation.provider_consent_digests = { 'openai' => consent_digest }
      operation.expected_items = articles.size
      operation.max_items = articles.size
      operation.started_at = Time.current
    end
  end

  def verify_operation!(operation)
    expected = [portal.id, user.id, 'translation', request_digest, consent_digest, articles.size]
    actual = [operation.portal_id, operation.user_id, operation.operation_type,
              operation.request_digest, operation.consent_digest, operation.expected_items]
    raise Conflict, 'lla_knowledge_idempotency_conflict' unless actual == expected
  end

  def persist_items_and_outboxes!(operation)
    article_payloads.each_with_index do |article_payload, index|
      persist_item_and_outbox!(operation, article_payload, index)
    end
  end

  def persist_item_and_outbox!(operation, article_payload, index) # rubocop:disable Metrics/AbcSize
    item_key = digest([operation.id, article_payload[:root_article_id], target_locale].join("\0"))
    item = operation.items.create_or_find_by!(ordinal: index) do |record|
      record.account = account
      record.portal = portal
      record.category = target_category
      record.item_type = 'translation'
      record.item_key_digest = item_key
      record.source_digest = article_payload.fetch(:source_digest)
    end
    unless [item.item_key_digest, item.source_digest, item.category_id] == [item_key, article_payload[:source_digest], target_category&.id]
      raise Conflict, 'lla_knowledge_idempotency_conflict'
    end

    persist_translation_outbox!(operation, item, article_payload, item_key)
  end # rubocop:enable Metrics/AbcSize

  def persist_translation_outbox!(operation, item, article_payload, item_key)
    payload = article_payload.merge(
      generation_item_id: item.id,
      target_locale: target_locale,
      target_category_id: target_category&.id,
      force: force
    )
    outbox_key = digest([operation.id, 'translate_article', item_key].join("\0"))
    outbox = operation.outboxes.create_or_find_by!(idempotency_digest: outbox_key) do |record|
      record.account = account
      record.portal = portal
      record.event_type = 'translate_article'
      record.available_at = Time.current
      record.payload = payload
    end
    expected_payload_digest = Lla::Knowledge::PayloadCipher.digest(payload)
    raise Conflict, 'lla_knowledge_idempotency_conflict' unless outbox.payload_digest == expected_payload_digest
  end

  def article_payloads
    @article_payloads ||= articles.sort_by(&:id).map do |article|
      {
        source_article_id: article.id,
        root_article_id: Article.find_root_article_id(article),
        source_digest: Lla::Knowledge::ArticleSearchDocument.digest(article)
      }
    end
  end

  def request_payload
    @request_payload ||= {
      articles: article_payloads,
      target_locale: target_locale,
      target_category_id: target_category&.id,
      force: force
    }
  end

  def normalized_idempotency_key
    idempotency_key || "translation:#{digest(JSON.generate(request_payload))}"
  end

  def idempotency_digest
    @idempotency_digest ||= digest([account.id, portal.id, normalized_idempotency_key].join("\0"))
  end

  def request_digest
    @request_digest ||= digest(JSON.generate(request_payload))
  end

  def consent_digest
    @consent_digest ||= Lla::Knowledge::ProviderPolicy.consent_digest(account, :openai)
  end

  def account_user
    @account_user ||= AccountUser.find_by(account_id: account&.id, user_id: user&.id)
  end

  def digest(value)
    Digest::SHA256.hexdigest(value)
  end
end
