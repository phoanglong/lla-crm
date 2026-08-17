# frozen_string_literal: true

class Lla::Knowledge::GenerationOutboxDispatchJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 50
  MAX_ATTEMPTS = 5
  EVENT_TYPES = %w[plan_generation write_article].freeze

  def perform(operation_id = nil)
    scope(operation_id).limit(BATCH_SIZE).pluck(:id).each { |outbox_id| dispatch_one(outbox_id) }
  end

  private

  def scope(operation_id)
    relation = Lla::Knowledge::GenerationOutbox.where(event_type: EVENT_TYPES, state: %w[pending failed])
                                               .where(available_at: ..Time.current)
                                               .order(:available_at, :id)
    operation_id.present? ? relation.where(generation_operation_id: operation_id) : relation
  end

  def dispatch_one(outbox_id)
    token = SecureRandom.uuid
    outbox = claim(outbox_id, token)
    return if outbox.blank?

    enqueue_event(outbox)
    mark_delivered(outbox, token)
  rescue StandardError => e
    mark_failed(outbox, token, e) if outbox
  end

  def claim(outbox_id, token)
    Lla::Knowledge::GenerationOutbox.transaction do
      outbox = Lla::Knowledge::GenerationOutbox.lock.find_by(id: outbox_id)
      next if outbox.blank? || %w[pending failed].exclude?(outbox.state) || outbox.available_at > Time.current
      next exhaust!(outbox) if outbox.attempts >= max_attempts(outbox)

      outbox.update!(state: 'claimed', attempts: outbox.attempts + 1,
                     claim_digest: digest(token), claimed_at: Time.current)
      outbox
    end
  end

  def enqueue_event(outbox)
    case outbox.event_type
    when 'plan_generation'
      Onboarding::HelpCenterArticleGenerationJob.perform_later(outbox.generation_operation_id)
    when 'write_article'
      Onboarding::HelpCenterArticleWriterJob.perform_later(outbox.id)
    else
      raise ArgumentError, 'unsupported knowledge outbox event'
    end
  end

  def mark_delivered(outbox, token)
    outbox.with_lock do
      next unless claimed_by?(outbox, token)

      outbox.update!(state: 'delivered', claim_digest: nil, delivered_at: Time.current)
    end
  end

  def mark_failed(outbox, token, error)
    outbox.with_lock do
      next unless claimed_by?(outbox, token)

      exhausted = outbox.attempts >= max_attempts(outbox)
      outbox.update!(
        state: 'failed',
        claim_digest: nil,
        claimed_at: nil,
        available_at: exhausted ? 48.hours.from_now : retry_at(outbox.attempts),
        last_error_code: error_code(error)
      )
    end
  end

  def exhaust!(outbox)
    outbox.update!(state: 'failed', claim_digest: nil, last_error_code: 'dispatch_exhausted',
                   available_at: 48.hours.from_now)
    nil
  end

  def max_attempts(outbox)
    [outbox.operation.max_attempts, MAX_ATTEMPTS].min
  end

  def claimed_by?(outbox, token)
    outbox.state == 'claimed' && outbox.claim_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(outbox.claim_digest, digest(token))
  end

  def retry_at(attempt)
    Time.current + ([attempt**2, 60].min.minutes)
  end

  def error_code(error)
    "dispatch_#{error.class.name.demodulize.underscore}".first(80)
  end

  def digest(token)
    Digest::SHA256.hexdigest(token)
  end
end
