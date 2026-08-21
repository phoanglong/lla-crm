# frozen_string_literal: true

# Atomically creates the durable generation operation and its first outbox
# intent. Raw URLs/hints exist only inside a short-lived encrypted payload;
# idempotency and conflict checks use tenant-bound SHA-256 digests.
class Lla::Knowledge::GenerationOperationService
  class InvalidRequest < StandardError; end
  class Conflict < StandardError; end

  IDEMPOTENCY_PATTERN = /\A[a-zA-Z0-9_.:-]{8,128}\z/
  MAX_PAYLOAD_BYTES = 64.kilobytes

  # Explicit keywords make the security context reviewable at each call site.
  # rubocop:disable Metrics/ParameterLists
  def initialize(account:, portal:, user:, idempotency_key:, operation_type:, event_type:, payload:,
                 provider:, capability:)
    @account = account
    @portal = portal
    @user = user
    @idempotency_key = idempotency_key.to_s
    @operation_type = operation_type.to_s
    @event_type = event_type.to_s
    @payload = payload.is_a?(Hash) ? payload.deep_symbolize_keys : payload
    @provider = provider.to_sym
    @capability = capability.to_sym
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    validate_request!
    Lla::Knowledge::ProviderPolicy.authorize_egress!(account: account, provider: provider, capability: capability)

    Lla::Knowledge::GenerationOperation.transaction(requires_new: true) do
      operation = create_or_find_operation
      verify_request!(operation)
      create_or_verify_outbox!(operation)
      operation
    end
  end

  private

  attr_reader :account, :portal, :user, :idempotency_key, :operation_type, :event_type, :payload, :provider, :capability

  def validate_request!
    validate_idempotency!
    validate_tenant!
    validate_types!
    validate_payload!
  end

  def validate_idempotency!
    raise InvalidRequest, 'invalid idempotency key' unless IDEMPOTENCY_PATTERN.match?(idempotency_key)
  end

  def validate_tenant!
    raise InvalidRequest, 'portal must belong to account' unless portal&.account_id == account&.id
    raise InvalidRequest, 'user must belong to account' unless AccountUser.exists?(account_id: account.id, user_id: user&.id)
  end

  def validate_types!
    raise InvalidRequest, 'unsupported operation type' unless operation_type.in?(Lla::Knowledge::GenerationOperation::TYPES)
    raise InvalidRequest, 'unsupported event type' unless event_type.in?(Lla::Knowledge::GenerationOutbox::EVENT_TYPES)
  end

  def validate_payload!
    raise InvalidRequest, 'payload must be an object' unless payload.is_a?(Hash)
    raise InvalidRequest, 'payload is too large' if canonical_json(payload).bytesize > MAX_PAYLOAD_BYTES
  end

  def create_or_find_operation
    Lla::Knowledge::GenerationOperation.create_or_find_by!(
      account: account,
      portal: portal,
      idempotency_digest: idempotency_digest
    ) do |operation|
      operation.user = user
      operation.operation_type = operation_type
      operation.request_digest = request_digest
      operation.consent_digest = consent_digest
    end
  end

  def verify_request!(operation)
    expected = [portal.id, user.id, operation_type, request_digest, consent_digest]
    actual = [operation.portal_id, operation.user_id, operation.operation_type,
              operation.request_digest, operation.consent_digest]
    raise Conflict, 'lla_knowledge_idempotency_conflict' unless actual == expected
  end

  def create_or_verify_outbox!(operation)
    outbox = operation.outboxes.create_or_find_by!(idempotency_digest: outbox_digest) do |record|
      record.account = account
      record.portal = portal
      record.event_type = event_type
      record.available_at = Time.current
      record.payload = payload
    end
    return if outbox.payload_digest == payload_digest && outbox.event_type == event_type

    raise Conflict, 'lla_knowledge_idempotency_conflict'
  end

  def idempotency_digest
    @idempotency_digest ||= digest([account.id, portal.id, idempotency_key].join("\0"))
  end

  def outbox_digest
    @outbox_digest ||= digest([idempotency_digest, event_type].join("\0"))
  end

  def request_digest
    @request_digest ||= digest(canonical_json(operation_type: operation_type, event_type: event_type, payload: payload))
  end

  def payload_digest
    @payload_digest ||= Lla::Knowledge::PayloadCipher.digest(payload)
  end

  def consent_digest
    @consent_digest ||= Lla::Knowledge::ProviderPolicy.consent_digest(account, provider)
  end

  def canonical_json(value)
    canonicalize(value).to_json
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort_by(&:to_s).index_with { |key| canonicalize(value[key]) }
    when Array
      value.map { |item| canonicalize(item) }
    else
      value
    end
  end

  def digest(value)
    Digest::SHA256.hexdigest(value)
  end
end
