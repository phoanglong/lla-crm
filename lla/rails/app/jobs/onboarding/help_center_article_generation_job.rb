# frozen_string_literal: true

class Onboarding::HelpCenterArticleGenerationJob < ApplicationJob
  queue_as :low

  CLAIM_TIMEOUT = 15.minutes

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.send(:terminal_failure, error)
  end

  def perform(operation_id)
    operation = Lla::Knowledge::GenerationOperation.find(operation_id)
    token = SecureRandom.uuid
    return unless claim_operation(operation, token)

    plan = Onboarding::HelpCenterCurator.new(account: operation.account, operation: operation).perform
    Lla::Knowledge::GenerationStateService.new(operation).plan!(plan)
    Lla::Knowledge::GenerationOutboxDispatchJob.perform_later(operation.id)
  rescue Lla::Knowledge::ProviderPolicy::Denied
    terminalize(operation, 'skipped', 'provider_disabled')
  rescue Onboarding::HelpCenterErrors::CurationSkipped => e
    terminalize(operation, 'skipped', e.code)
  rescue StandardError
    release_operation(operation, token) if operation && token
    raise
  end

  private

  def claim_operation(operation, token)
    operation.with_lock do
      next false if operation.terminal? || operation.state.in?(%w[dispatching running])
      next false if operation.claim_digest.present? && operation.claimed_at&.after?(CLAIM_TIMEOUT.ago)

      operation.update!(state: 'planning', claim_digest: digest(operation, token), claimed_at: Time.current,
                        started_at: operation.started_at || Time.current)
    end
    true
  end

  def release_operation(operation, token)
    operation.with_lock do
      next unless claim_matches?(operation, token)

      operation.update!(state: 'pending', claim_digest: nil, claimed_at: nil,
                        last_error_code: 'planning_retry')
    end
  end

  def terminal_failure(error)
    operation = Lla::Knowledge::GenerationOperation.find_by(id: arguments.first)
    terminalize(operation, 'failed', "planning_#{error.class.name.demodulize.underscore}") if operation
  end

  def terminalize(operation, state, code)
    return if operation.blank?

    Lla::Knowledge::GenerationStateService.new(operation).terminalize!(state: state, error_code: code)
  end

  def claim_matches?(operation, token)
    operation.claim_digest.present? && ActiveSupport::SecurityUtils.secure_compare(operation.claim_digest, digest(operation, token))
  end

  def digest(operation, token)
    Digest::SHA256.hexdigest([operation.id, token].join("\0"))
  end
end
