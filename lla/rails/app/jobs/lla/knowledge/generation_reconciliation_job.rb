# frozen_string_literal: true

class Lla::Knowledge::GenerationReconciliationJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 100
  CLAIM_TIMEOUT = 20.minutes
  DELIVERY_TIMEOUT = 30.minutes

  def perform
    recover_outbox_claims
    recover_operation_claims
    recover_items
    settle_operations
    dispatch_ready_outboxes
  end

  private

  def recover_outbox_claims
    ids = Lla::Knowledge::GenerationOutbox.where(
      event_type: Lla::Knowledge::GenerationOutboxDispatchJob::EVENT_TYPES,
      state: 'claimed', claimed_at: ..CLAIM_TIMEOUT.ago
    )
                                          .order(:claimed_at, :id).limit(BATCH_SIZE).pluck(:id)
    ids.each do |id|
      Lla::Knowledge::GenerationOutbox.transaction do
        outbox = Lla::Knowledge::GenerationOutbox.lock.find_by(id: id)
        next unless outbox&.state == 'claimed' && outbox.claimed_at&.before?(CLAIM_TIMEOUT.ago)

        outbox.update!(state: 'failed', claim_digest: nil, claimed_at: nil,
                       available_at: Time.current, last_error_code: 'stale_dispatch_claim')
      end
    end
  end

  def recover_operation_claims # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    ids = Lla::Knowledge::GenerationOperation.where(operation_type: 'onboarding', state: %w[pending planning])
                                             .where('claimed_at IS NULL OR claimed_at <= ?', CLAIM_TIMEOUT.ago)
                                             .order(:updated_at, :id).limit(BATCH_SIZE).pluck(:id)
    ids.each do |id|
      operation = Lla::Knowledge::GenerationOperation.find_by(id: id)
      next if operation.blank?

      terminal_code = nil
      operation.with_lock do
        next unless operation.state.in?(%w[pending planning])
        next if operation.state == 'planning' && operation.claimed_at&.after?(CLAIM_TIMEOUT.ago)

        plan_outbox = operation.outboxes.find_by(event_type: 'plan_generation')
        terminal_code = 'planning_outbox_missing' if plan_outbox.blank?
        terminal_code = 'planning_dispatch_exhausted' if plan_outbox && plan_outbox.attempts >= operation.max_attempts
        next if terminal_code

        if operation.state == 'planning'
          operation.update!(state: 'pending', claim_digest: nil, claimed_at: nil,
                            last_error_code: 'stale_planning_claim')
        end
        requeue_outbox(plan_outbox) if delivery_lost?(plan_outbox)
      end
      terminalize(operation, terminal_code) if terminal_code
    end
  end # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def recover_items
    ids = Lla::Knowledge::GenerationItem.joins(:operation)
                                        .where(lla_knowledge_generation_operations: { operation_type: 'onboarding' })
                                        .where(state: %w[pending claimed])
                                        .where(
                                          'lla_knowledge_generation_items.claimed_at IS NULL OR ' \
                                          'lla_knowledge_generation_items.claimed_at <= ?', CLAIM_TIMEOUT.ago
                                        )
                                        .order('lla_knowledge_generation_items.updated_at, ' \
                                               'lla_knowledge_generation_items.id')
                                        .limit(BATCH_SIZE).pluck('lla_knowledge_generation_items.id')
    ids.each { |id| recover_item(id) }
  end

  def recover_item(id) # rubocop:disable Metrics/CyclomaticComplexity
    item = Lla::Knowledge::GenerationItem.find_by(id: id)
    return if item.blank? || item.operation.terminal?

    item.operation.with_lock do
      item.lock!
      next if item.state.in?(Lla::Knowledge::GenerationStateService::TERMINAL_ITEM_STATES)

      if item.state == 'claimed' && item.claimed_at&.before?(CLAIM_TIMEOUT.ago)
        if item.attempts >= item.operation.max_attempts
          Lla::Knowledge::GenerationStateService.new(item.operation).fail_item!(
            item.id, error_code: 'writer_retry_exhausted'
          )
          next
        end
        item.update!(state: 'pending', claim_digest: nil, claimed_at: nil,
                     last_error_code: 'stale_writer_claim')
      end
      recover_item_outbox(item)
    end
  end # rubocop:enable Metrics/CyclomaticComplexity

  def recover_item_outbox(item)
    outbox = writer_outbox(item)
    return fail_unrecoverable_item(item, 'writer_outbox_missing') if outbox.blank?
    return fail_unrecoverable_item(item, 'writer_dispatch_exhausted') if outbox.attempts >= item.operation.max_attempts
    return unless delivery_lost?(outbox)

    requeue_outbox(outbox)
  end

  def writer_outbox(item)
    item.operation.outboxes.where(event_type: 'write_article').find do |outbox|
      outbox.payload[:generation_item_id].to_i == item.id
    rescue Lla::Knowledge::PayloadCipher::InvalidPayload
      false
    end
  end

  def requeue_outbox(outbox)
    return if outbox.blank? || outbox.state.in?(%w[pending claimed cancelled failed])

    outbox.update!(state: 'pending', claim_digest: nil, claimed_at: nil,
                   available_at: Time.current, last_error_code: nil)
  end

  def fail_unrecoverable_item(item, code)
    Lla::Knowledge::GenerationStateService.new(item.operation).fail_item!(item.id, error_code: code)
  end

  def terminalize(operation, code)
    Lla::Knowledge::GenerationStateService.new(operation).terminalize!(state: 'failed', error_code: code)
  end

  def delivery_lost?(outbox)
    outbox.state == 'delivered' && (outbox.delivered_at.blank? || outbox.delivered_at.before?(DELIVERY_TIMEOUT.ago))
  end

  def settle_operations
    ids = Lla::Knowledge::GenerationOperation.where(
      operation_type: 'onboarding', state: %w[dispatching running]
    )
                                             .order(:updated_at, :id).limit(BATCH_SIZE).pluck(:id)
    ids.each { |id| settle_operation(id) }
  end

  def settle_operation(id)
    operation = Lla::Knowledge::GenerationOperation.find_by(id: id)
    return if operation.blank?

    operation.with_lock { settle_locked_operation(operation) }
  end

  def settle_locked_operation(operation)
    counts = operation.items.group(:state).count
    return if unfinished_item_count(counts).positive?

    return mark_item_count_mismatch(operation, counts) if item_count_mismatch?(operation, counts)

    mark_operation_settled(operation, counts)
  end

  def unfinished_item_count(counts)
    counts.fetch('pending', 0) + counts.fetch('claimed', 0)
  end

  def item_count_mismatch?(operation, counts)
    operation.expected_items.zero? || counts.values.sum != operation.expected_items
  end

  def mark_item_count_mismatch(operation, counts)
    operation.update!(
      state: 'failed', finished_items: finished_item_count(counts), failed_items: counts.fetch('failed', 0),
      last_error_code: 'writer_item_count_mismatch', claim_digest: nil,
      claimed_at: nil, completed_at: Time.current
    )
  end

  def mark_operation_settled(operation, counts)
    failed = counts.fetch('failed', 0)
    cancelled = counts.fetch('cancelled', 0)
    state = if cancelled.positive?
              'failed'
            elsif failed.positive?
              'completed_with_errors'
            else
              'completed'
            end
    error_code = cancelled.positive? ? 'unexpected_cancelled_item' : operation.last_error_code

    operation.update!(state: state, finished_items: finished_item_count(counts), failed_items: failed,
                      last_error_code: error_code, claim_digest: nil, claimed_at: nil, completed_at: Time.current)
  end

  def finished_item_count(counts)
    counts.fetch('failed', 0) + counts.fetch('succeeded', 0)
  end

  def dispatch_ready_outboxes
    return unless Lla::Knowledge::GenerationOutbox.exists?(
      event_type: Lla::Knowledge::GenerationOutboxDispatchJob::EVENT_TYPES,
      state: %w[pending failed], available_at: ..Time.current
    )

    Lla::Knowledge::GenerationOutboxDispatchJob.perform_later
  end
end
