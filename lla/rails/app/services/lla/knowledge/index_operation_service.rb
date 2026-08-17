# frozen_string_literal: true

class Lla::Knowledge::IndexOperationService
  class InvalidRequest < StandardError; end
  class Conflict < StandardError; end

  def initialize(article:)
    @article = article
  end

  def perform
    validate!
    authorize!
    Lla::Knowledge::GenerationOperation.transaction(requires_new: true) do
      operation = create_or_find_operation
      verify_operation!(operation)
      persist_item_and_outbox!(operation)
      operation
    end
  end

  private

  attr_reader :article

  def validate!
    raise InvalidRequest, 'article must be persisted' unless article&.persisted?
    raise InvalidRequest, 'article tenant is inconsistent' unless article.portal&.account_id == article.account_id
    raise InvalidRequest, 'embedding search is unavailable' unless article.account.feature_enabled?('help_center_embedding_search')

    validate_search_state!
    raise InvalidRequest, 'index actor is unavailable' if actor.blank?

    Captain::Llm::EmbeddingService.embedding_profile
  end

  def validate_search_state!
    digest_valid = article.lla_search_content_digest.to_s.match?(/\A[0-9a-f]{64}\z/)
    raise InvalidRequest, 'article search digest is invalid' unless digest_valid
    raise InvalidRequest, 'article search version is invalid' unless article.lla_search_version.to_i.positive?
  end

  def authorize!
    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: article.account, provider: :openai, capability: :embedding_search
    )
  end

  def create_or_find_operation
    Lla::Knowledge::GenerationOperation.create_or_find_by!(
      account: article.account, portal: article.portal, idempotency_digest: idempotency_digest
    ) do |operation|
      operation.user = actor
      operation.operation_type = 'reindex'
      operation.state = 'dispatching'
      operation.request_digest = request_digest
      operation.consent_digest = consent_digest
      operation.provider_consent_digests = { 'openai' => consent_digest }
      operation.expected_items = 1
      operation.max_items = 1
      operation.started_at = Time.current
    end
  end

  def verify_operation!(operation)
    expected = [article.portal_id, actor.id, 'reindex', request_digest, consent_digest]
    actual = [operation.portal_id, operation.user_id, operation.operation_type,
              operation.request_digest, operation.consent_digest]
    raise Conflict, 'lla_knowledge_idempotency_conflict' unless actual == expected
  end

  def persist_item_and_outbox!(operation)
    item = persist_item!(operation)
    persist_outbox!(operation, item)
  end

  def persist_item!(operation)
    operation.items.create_or_find_by!(ordinal: 0) do |record|
      record.account = article.account
      record.portal = article.portal
      record.item_type = 'reindex'
      record.item_key_digest = item_digest
      record.source_digest = article.lla_search_content_digest
    end
  end

  def persist_outbox!(operation, item)
    raise Conflict, 'lla_knowledge_idempotency_conflict' unless item.item_key_digest == item_digest

    expected_payload = payload.merge(generation_item_id: item.id)
    outbox = operation.outboxes.create_or_find_by!(idempotency_digest: outbox_digest) do |record|
      record.account = article.account
      record.portal = article.portal
      record.event_type = 'rebuild_index'
      record.available_at = Time.current
      record.payload = expected_payload
    end
    expected_digest = Lla::Knowledge::PayloadCipher.digest(expected_payload)
    raise Conflict, 'lla_knowledge_idempotency_conflict' unless outbox.payload_digest == expected_digest
  end

  def actor
    @actor ||= if AccountUser.exists?(account_id: article.account_id, user_id: article.author_id)
                 article.author
               else
                 article.account.account_users.administrator.includes(:user).first&.user
               end
  end

  def payload
    @payload ||= {
      article_id: article.id,
      content_digest: article.lla_search_content_digest,
      index_version: article.lla_search_version,
      model: profile.fetch(:model),
      dimensions: profile.fetch(:dimensions)
    }
  end

  def profile
    @profile ||= Captain::Llm::EmbeddingService.embedding_profile
  end

  def idempotency_digest
    @idempotency_digest ||= digest([article.account_id, article.portal_id, 'reindex', *payload.values].join("\0"))
  end

  def request_digest
    @request_digest ||= digest(JSON.generate(payload))
  end

  def item_digest
    @item_digest ||= digest([idempotency_digest, article.id, article.lla_search_content_digest].join("\0"))
  end

  def outbox_digest
    @outbox_digest ||= digest([idempotency_digest, 'rebuild_index'].join("\0"))
  end

  def consent_digest
    @consent_digest ||= Lla::Knowledge::ProviderPolicy.consent_digest(article.account, :openai)
  end

  def digest(value)
    Digest::SHA256.hexdigest(value)
  end
end
