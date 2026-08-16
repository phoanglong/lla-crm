# frozen_string_literal: true

require 'digest'

# Updates only allowlisted embedding records and discards stale jobs after the
# provider call. The legacy GlobalID signature remains supported for the
# ArticleEmbedding callback until its owning Help Center wave migrates.
class Captain::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  ALLOWED_CONTENT_ATTRIBUTES = {
    'ArticleEmbedding' => :term
  }.freeze
  MAX_CONTENT_BYTES = 64_000

  def perform(record_or_type, content_or_id = nil, account_id: nil, content_digest: nil)
    record, expected_content = resolve_request(record_or_type, content_or_id, account_id, content_digest)
    return unless record && expected_content

    embedding = Captain::Llm::EmbeddingService.new(account_id: record.account_id).get_embedding(expected_content)
    persist_if_current(record, expected_content, embedding)
  rescue ActiveRecord::RecordNotFound
    nil
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: record&.try(:account)).capture_exception
    Rails.logger.warn("LLA embedding update failed record_type=#{record&.class&.name} record_id=#{record&.id} error=#{e.class.name}")
    raise
  end

  private

  def resolve_request(record_or_type, content_or_id, account_id, content_digest)
    return resolve_typed_request(record_or_type, content_or_id, account_id, content_digest) if record_or_type.is_a?(String)

    resolve_legacy_request(record_or_type, content_or_id)
  end

  def resolve_typed_request(record_type, record_id, account_id, content_digest)
    attribute = ALLOWED_CONTENT_ATTRIBUTES[record_type]
    klass = record_type.safe_constantize if attribute
    return unless klass

    record = klass.find_by(id: record_id)
    return unless record && record.account_id == account_id.to_i

    content = bounded_content(record.public_send(attribute))
    return unless secure_digest_match?(content, content_digest)

    [record, content]
  end

  def resolve_legacy_request(record, content)
    attribute = ALLOWED_CONTENT_ATTRIBUTES[record.class.name]
    return unless attribute && record.persisted?

    current = record.class.find_by(id: record.id)
    expected_content = bounded_content(content)
    return unless current && bounded_content(current.public_send(attribute)) == expected_content

    [current, expected_content]
  end

  def persist_if_current(record, expected_content, embedding)
    attribute = ALLOWED_CONTENT_ATTRIBUTES.fetch(record.class.name)
    record.with_lock do
      record.reload
      next unless bounded_content(record.public_send(attribute)) == expected_content

      record.update!(embedding: embedding)
    end
  end

  def bounded_content(content)
    value = content.to_s.scrub
    return if value.blank? || value.bytesize > MAX_CONTENT_BYTES

    value
  end

  def secure_digest_match?(content, content_digest)
    return false if content.blank? || content_digest.to_s.bytesize != 64

    ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(content), content_digest.to_s.downcase)
  end
end
