# frozen_string_literal: true

# The service keeps claim, execution and immutable-result replay together so
# idempotency invariants can be reviewed in one place.
# rubocop:disable Metrics/ClassLength
class Lla::Captain::BulkActionService
  class InvalidRequest < StandardError; end
  class Conflict < StandardError; end
  class InProgress < StandardError; end
  class OperationFailed < StandardError; end

  MAX_BATCH_SIZE = 100
  MAX_OPERATION_ID_BYTES = 128
  PROCESSING_STALE_AFTER = 10.minutes
  SYNC_CLAIM_STALE_AFTER = 2.hours
  RESOURCE_ACTIONS = {
    'AssistantResponse' => %w[delete],
    'AssistantDocument' => %w[delete sync]
  }.freeze
  PROCESSED_STATUSES = %w[deleted queued].freeze

  def initialize(account:, user:, **request)
    @account = account
    @user = user
    @resource_type = request.fetch(:resource_type).to_s
    @action = request.fetch(:action).to_s
    @raw_ids = Array(request[:ids])
    parsed_ids = raw_ids.map { |id| Integer(id, exception: false) }
    @invalid_ids = parsed_ids.any?(&:nil?) || parsed_ids.compact.any? { |id| !id.positive? }
    @ids = parsed_ids.compact.uniq.sort
    @operation_id = request[:operation_id].to_s
    validate_request!
  end

  def perform
    operation = find_or_create_operation
    replay = claim_operation(operation)
    return replay if replay

    result = execute_action
    operation.update!(
      state: 'completed',
      result: result,
      processed_count: result.fetch(:processed_count),
      error_count: result.fetch(:error_count),
      completed_at: Time.current
    )
    instrument(operation, result)
    result
  rescue InvalidRequest, Conflict, InProgress
    raise
  rescue StandardError => e
    fail_operation(operation, e) if operation
    raise OperationFailed, 'Bulk operation failed'
  end

  private

  attr_reader :account, :user, :resource_type, :action, :ids, :operation_id, :raw_ids

  def validate_request!
    validate_resource_action!
    validate_ids!
    validate_operation_id!
  end

  def validate_resource_action!
    allowed_actions = RESOURCE_ACTIONS[resource_type]
    raise InvalidRequest, 'Unsupported resource type or action' unless allowed_actions&.include?(action)
  end

  def validate_ids!
    raise InvalidRequest, 'ids must be a non-empty positive integer array' if ids.empty? || @invalid_ids
    raise InvalidRequest, "Batch exceeds #{MAX_BATCH_SIZE} records" if raw_ids.length > MAX_BATCH_SIZE
  end

  def validate_operation_id!
    raise InvalidRequest, 'operation_id is required' if operation_id.blank?
    raise InvalidRequest, 'operation_id is too large' if operation_id.bytesize > MAX_OPERATION_ID_BYTES
  end

  def find_or_create_operation
    Lla::Captain::BulkOperation.find_or_create_by!(account_id: account.id, key_digest: operation_key_digest) do |operation|
      operation.user = user
      operation.request_digest = request_digest
      operation.resource_type = resource_type
      operation.action = action
      operation.requested_count = ids.length
    end
  end

  def claim_operation(operation)
    replay = nil
    operation.with_lock do
      raise Conflict, 'operation_id belongs to a different request' unless matching_operation?(operation)

      if %w[completed failed].include?(operation.state)
        replay = operation.result.deep_symbolize_keys
        next
      end
      if operation.state == 'processing' && operation.started_at.present? && operation.started_at > PROCESSING_STALE_AFTER.ago
        raise InProgress, 'operation is already in progress'
      end

      operation.update!(state: 'processing', started_at: Time.current)
    end
    replay
  end

  def matching_operation?(operation)
    operation.user_id == user.id && operation.request_digest == request_digest &&
      operation.resource_type == resource_type && operation.action == action
  end

  def execute_action
    return delete_records(Captain::AssistantResponse, account.captain_assistant_responses) if resource_type == 'AssistantResponse'
    return delete_records(Captain::Document, account.captain_documents) if action == 'delete'

    sync_documents
  end

  def delete_records(model, scope)
    records = scope.where(id: ids).index_by(&:id)
    model.transaction { records.each_value(&:destroy!) }
    outcomes = ids.map { |id| { id: id, status: records.key?(id) ? 'deleted' : 'not_found' } }

    build_result(outcomes)
  end

  def sync_documents
    documents = account.captain_documents.where(id: ids).index_by(&:id)
    outcomes = ids.map do |id|
      document = documents[id]
      next { id: id, status: 'not_found' } unless document

      enqueue_document_sync(document)
    end

    build_result(outcomes, effective_ids: outcomes.filter_map { |outcome| outcome[:id] if outcome[:status] == 'queued' })
  end

  def enqueue_document_sync(document)
    claim = claim_document_sync(document)
    return { id: document.id, status: claim.fetch(:status) } unless claim[:token]

    job = Captain::Documents::PerformSyncJob.perform_later(document, claim.fetch(:token))
    raise ActiveJob::EnqueueError, 'Sync enqueue was rejected' unless job
    raise job.enqueue_error if job.respond_to?(:enqueue_error) && job.enqueue_error

    { id: document.id, status: 'queued' }
  rescue StandardError
    release_document_claim(document, claim&.dig(:token), error_code: 'enqueue_failed')
    { id: document.id, status: 'enqueue_failed' }
  end

  def claim_document_sync(document)
    token = SecureRandom.hex(32)
    status = nil
    document.with_lock do
      document.reload
      status = document_sync_rejection(document)
      next if status

      document.update!(
        sync_status: :pending,
        sync_step: nil,
        last_sync_error_code: nil,
        last_sync_attempted_at: Time.current,
        sync_claim_digest: sync_claim_digest(document, token),
        sync_claimed_at: Time.current
      )
    end

    status ? { status: status } : { status: 'queued', token: token }
  end

  def document_sync_rejection(document)
    return 'not_syncable' unless document.syncable?
    return 'not_available' unless document.available?
    return 'already_claimed' if active_sync_claim?(document)
    return 'already_syncing' if document.sync_in_progress?
  end

  def active_sync_claim?(document)
    document.sync_claim_digest.present? && document.sync_claimed_at.present? &&
      document.sync_claimed_at > SYNC_CLAIM_STALE_AFTER.ago
  end

  def release_document_claim(document, token, error_code: nil)
    return if token.blank?

    document.with_lock do
      document.reload
      next unless secure_claim_match?(document, token)

      document.update!(
        sync_status: error_code ? :failed : document.sync_status,
        last_sync_error_code: error_code,
        sync_claim_digest: nil,
        sync_claimed_at: nil
      )
    end
  end

  def secure_claim_match?(document, token)
    digest = sync_claim_digest(document, token)
    stored = document.sync_claim_digest.to_s
    stored.bytesize == digest.bytesize && ActiveSupport::SecurityUtils.secure_compare(stored, digest)
  end

  def sync_claim_digest(document, token)
    Digest::SHA256.hexdigest("#{account.id}\0#{document.id}\0#{token}")
  end

  def build_result(outcomes, effective_ids: nil)
    processed_count = outcomes.count { |outcome| PROCESSED_STATUSES.include?(outcome[:status]) }
    error_count = outcomes.count { |outcome| outcome[:status] == 'enqueue_failed' }
    {
      success: error_count.zero?,
      resource_type: resource_type,
      action: action,
      requested_count: ids.length,
      processed_count: processed_count,
      error_count: error_count,
      ids: effective_ids || outcomes.filter_map { |outcome| outcome[:id] if PROCESSED_STATUSES.include?(outcome[:status]) },
      outcomes: outcomes
    }
  end

  def operation_key_digest
    @operation_key_digest ||= Digest::SHA256.hexdigest("#{account.id}\0#{operation_id}")
  end

  def request_digest
    @request_digest ||= Digest::SHA256.hexdigest(
      ActiveSupport::JSON.encode(resource_type: resource_type, action: action, ids: ids)
    )
  end

  def fail_operation(operation, error)
    result = {
      success: false,
      error_code: 'operation_failed',
      requested_count: ids.length,
      processed_count: 0,
      error_count: ids.length,
      outcomes: []
    }
    operation.update!(state: 'failed', result: result, error_count: ids.length, completed_at: Time.current)
    Rails.logger.warn(
      "LLA Captain bulk operation failed account_id=#{account.id} operation_id=#{operation.id} error_class=#{error.class.name}"
    )
  rescue StandardError => e
    Rails.logger.error(
      "LLA Captain bulk failure audit failed account_id=#{account.id} error_class=#{e.class.name}"
    )
  end

  def instrument(operation, result)
    ActiveSupport::Notifications.instrument(
      'lla.captain.bulk_operation',
      account_id: account.id,
      user_id: user.id,
      operation_id: operation.id,
      resource_type: resource_type,
      action: action,
      requested_count: ids.length,
      processed_count: result.fetch(:processed_count),
      error_count: result.fetch(:error_count)
    )
  end
end
# rubocop:enable Metrics/ClassLength
