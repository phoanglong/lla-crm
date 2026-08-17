# frozen_string_literal: true

class Portal::ArticleIndexingJob < ApplicationJob
  class StaleArticle < StandardError; end

  queue_as :low

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.send(:terminal_failure, error)
  end

  def perform(reference)
    return schedule_legacy(reference) if reference.is_a?(Article)

    perform_outbox(reference)
  end

  private

  def perform_outbox(outbox_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    outbox = Lla::Knowledge::GenerationOutbox.find(outbox_id)
    raise ArgumentError, 'invalid reindex outbox event' unless outbox.event_type == 'rebuild_index'

    operation = outbox.operation
    payload = outbox.payload
    item = operation.items.find(payload.fetch(:generation_item_id))
    token = SecureRandom.uuid
    claimed = Lla::Knowledge::GenerationStateService.new(operation).claim_item!(item.id, token: token)
    return if claimed.blank?

    article = validated_article(operation, payload)
    terms = article.generate_article_search_terms
    raise StaleArticle, 'article has no indexable terms' if terms.empty?

    quota = reserve_quota(operation, claimed, terms.size)
    return fail_item(operation, claimed, token, 'embedding_quota_exhausted') unless quota[:result].acquired?

    vectors = terms.map { |term| embedding_service(operation).get_embedding(term) }
    activate_shadow!(article, payload, terms.zip(vectors))
    Lla::Knowledge::GenerationStateService.new(operation).complete_reindex_item!(item.id, token: token)
    quota[:manager].consume!
  rescue Lla::Knowledge::PayloadCipher::InvalidPayload
    terminalize_invalid_payload(operation || outbox&.operation)
  rescue Lla::Knowledge::ProviderPolicy::Denied, Captain::Llm::EmbeddingService::UnsupportedModel,
         Captain::Llm::EmbeddingService::InvalidEmbedding, StaleArticle => e
    quota&.dig(:manager)&.release!
    fail_item(operation, item, token, "embedding_#{e.class.name.demodulize.underscore}")
  rescue StandardError => e
    quota&.dig(:manager)&.release!
    release_item(operation, item, token, e)
    raise
  end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def schedule_legacy(article)
    operation = Lla::Knowledge::IndexOperationService.new(article: article).perform
    Lla::Knowledge::GenerationOutboxDispatchJob.perform_later(operation.id)
  end

  def validated_article(operation, payload)
    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: operation.account, provider: :openai, capability: :embedding_search
    )
    article = operation.portal.articles.find(payload.fetch(:article_id))
    profile = Captain::Llm::EmbeddingService.embedding_profile
    expected = [operation.account_id, payload.fetch(:content_digest), payload.fetch(:index_version).to_i,
                payload.fetch(:model), payload.fetch(:dimensions).to_i]
    actual = [article.account_id, article.lla_search_content_digest, article.lla_search_version,
              profile.fetch(:model), profile.fetch(:dimensions)]
    raise StaleArticle, 'article index request is stale' unless expected == actual

    article
  end

  def reserve_quota(operation, item, units)
    owner_token = SecureRandom.uuid
    manager = Lla::Captain::QuotaManager.new(
      account: operation.account,
      idempotency_key: "article-index:#{operation.id}:#{item.id}:#{item.attempts}",
      owner_token: owner_token,
      feature: 'help_center_embedding_search',
      provider: 'openai',
      credential_source: 'system',
      reason: 'article_index_build',
      units: units
    )
    { manager: manager, result: manager.reserve! }
  end

  def embedding_service(operation)
    Captain::Llm::EmbeddingService.new(account_id: operation.account_id)
  end

  def activate_shadow!(article, payload, term_vectors) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Article.transaction do
      article.lock!
      article.reload
      current_request = [article.lla_search_content_digest, article.lla_search_version]
      expected_request = [payload.fetch(:content_digest), payload.fetch(:index_version).to_i]
      raise StaleArticle, 'article changed during index build' unless current_request == expected_request

      version_scope = article.article_embeddings.where(
        model: payload.fetch(:model), index_version: payload.fetch(:index_version).to_i
      )
      version_scope.delete_all
      created = term_vectors.map do |term, vector|
        article.article_embeddings.create!(
          account_id: article.account_id,
          portal_id: article.portal_id,
          model: payload.fetch(:model),
          dimensions: payload.fetch(:dimensions).to_i,
          content_digest: payload.fetch(:content_digest),
          term_digest: Digest::SHA256.hexdigest(term),
          index_version: payload.fetch(:index_version).to_i,
          term: term,
          embedding: vector,
          active: false
        )
      end
      article.article_embeddings.where.not(id: created.map(&:id)).update_all(active: false) # rubocop:disable Rails/SkipsModelValidations
      article.article_embeddings.where(id: created.map(&:id)).update_all(active: true) # rubocop:disable Rails/SkipsModelValidations
      article.update!(
        lla_search_active_version: payload.fetch(:index_version).to_i,
        lla_search_embedding_model: payload.fetch(:model),
        lla_search_embedding_dimensions: payload.fetch(:dimensions).to_i
      )
    end
  end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def release_item(operation, item, token, error)
    return if operation.blank? || item.blank? || token.blank?

    Lla::Knowledge::GenerationStateService.new(operation).release_item!(
      item.id, token: token, error_code: "embedding_#{error.class.name.demodulize.underscore}"
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
      item_id, error_code: "embedding_#{error.class.name.demodulize.underscore}"
    )
  rescue Lla::Knowledge::PayloadCipher::InvalidPayload
    terminalize_invalid_payload(outbox&.operation)
  rescue ArgumentError, ActiveRecord::RecordNotFound
    nil
  end

  def terminalize_invalid_payload(operation)
    return if operation.blank?

    Lla::Knowledge::GenerationStateService.new(operation).terminalize!(
      state: 'failed', error_code: 'embedding_payload_invalid'
    )
  end
end
