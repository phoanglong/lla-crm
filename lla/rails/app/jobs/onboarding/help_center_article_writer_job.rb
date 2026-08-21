# frozen_string_literal: true

class Onboarding::HelpCenterArticleWriterJob < ApplicationJob
  queue_as :low

  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    job.send(:terminal_failure, error)
  end

  def perform(outbox_id) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    outbox = Lla::Knowledge::GenerationOutbox.find(outbox_id)
    raise ArgumentError, 'invalid writer outbox event' unless outbox.event_type == 'write_article'

    operation = outbox.operation
    payload = outbox.payload
    item = operation.items.find(payload.fetch(:generation_item_id))
    token = SecureRandom.uuid
    claimed = Lla::Knowledge::GenerationStateService.new(operation).claim_item!(item.id, token: token)
    return if claimed.blank?

    attributes = Onboarding::HelpCenterArticleBuilder.new(
      account: operation.account,
      portal: operation.portal,
      user: operation.user,
      operation: operation,
      item: claimed,
      article: payload
    ).perform
    Lla::Knowledge::GenerationStateService.new(operation).complete_item!(
      item.id, token: token, article_attributes: attributes
    )
  rescue Lla::Knowledge::PayloadCipher::InvalidPayload
    terminalize_invalid_payload(operation || outbox&.operation)
  rescue Lla::Knowledge::ProviderPolicy::Denied
    fail_item(operation, item, token, 'provider_disabled')
  rescue StandardError => e
    release_item(operation, item, token, e)
    raise
  end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  private

  def release_item(operation, item, token, error)
    return if operation.blank? || item.blank? || token.blank?

    Lla::Knowledge::GenerationStateService.new(operation).release_item!(
      item.id, token: token, error_code: "writer_#{error.class.name.demodulize.underscore}"
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
      item_id, error_code: "writer_#{error.class.name.demodulize.underscore}"
    )
  rescue Lla::Knowledge::PayloadCipher::InvalidPayload
    terminalize_invalid_payload(outbox&.operation)
  rescue ArgumentError, ActiveRecord::RecordNotFound
    nil
  end

  def terminalize_invalid_payload(operation)
    return if operation.blank?

    Lla::Knowledge::GenerationStateService.new(operation).terminalize!(
      state: 'failed', error_code: 'writer_payload_invalid'
    )
  end
end
