# frozen_string_literal: true

class CopilotMessage < ApplicationRecord
  include Lla::CopilotMessageQuota

  ALLOWED_MESSAGE_KEYS = %w[content reasoning function_name reply_suggestion].freeze
  STRING_MESSAGE_KEYS = %w[content reasoning function_name].freeze
  MESSAGE_BYTES_LIMIT = 49_152
  VALUE_BYTES_LIMIT = 32_768
  RESPONSE_TOKEN_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  belongs_to :copilot_thread, inverse_of: :copilot_messages
  belongs_to :account
  belongs_to :conversation, optional: true
  belongs_to :source_message, class_name: 'CopilotMessage', optional: true, inverse_of: :copilot_response
  has_one :copilot_response, class_name: 'CopilotMessage', foreign_key: :source_message_id,
                             dependent: :nullify, inverse_of: :source_message

  enum :message_type, { user: 0, assistant: 1, assistant_thinking: 2 }
  enum :response_state, { none: 0, reserved: 1, processing: 2, completed: 3, released: 4 }, prefix: :response

  validates :message_type, presence: true
  validates :message, presence: true
  before_validation :ensure_account
  validate :validate_message_attributes
  validate :validate_tenant_context
  validate :validate_response_workflow
  after_create_commit :broadcast_message

  def push_event_data
    {
      id: id,
      message: message,
      message_type: message_type,
      created_at: created_at.to_i,
      copilot_thread: copilot_thread.push_event_data
    }
  end

  def enqueue_response_job
    raise ActiveJob::EnqueueError, 'Copilot response is not reserved' unless response_reserved?

    job = Captain::Copilot::ResponseJob.perform_later(message_id: id, reservation_token: response_job_token)
    raise ActiveJob::EnqueueError, 'Copilot response could not be enqueued' if job.respond_to?(:successfully_enqueued?) && !job.successfully_enqueued?

    job
  rescue StandardError => e
    release_response!
    persist_failure_response!
    raise ActiveJob::EnqueueError, e.class.name
  end

  def schedule_response!
    unless reserve_response!
      persist_limit_response!
      return :limited
    end

    enqueue_response_job
    :queued
  rescue ActiveJob::EnqueueError => e
    Rails.logger.error("LLA Copilot enqueue failed message_id=#{id} error=#{e.class.name}")
    :failed
  end

  def claim_response!(token)
    with_lock do
      next :finished if response_completed? || response_released?
      next :invalid unless reservable_token?(token)
      next :out_of_order if earlier_response_pending?

      update!(response_state: :processing, response_attempts: response_attempts + 1)
      :claimed
    end
  end

  def reset_response_for_retry!(token)
    with_lock do
      next false unless response_processing? && reservable_token?(token)

      update!(response_state: :reserved)
      true
    end
  end

  def persist_failure_response!
    return copilot_response if copilot_response.present?

    copilot_thread.copilot_messages.create!(
      message_type: :assistant,
      source_message: self,
      message: { 'content' => I18n.t('captain.copilot_generation_failed', default: 'Copilot could not generate a response. Please try again.') }
    )
  rescue ActiveRecord::RecordNotUnique
    reload.copilot_response
  end

  def persist_limit_response!
    return copilot_response if copilot_response.present?

    copilot_thread.copilot_messages.create!(
      message_type: :assistant,
      source_message: self,
      message: { 'content' => I18n.t('captain.copilot_limit') }
    )
  rescue ActiveRecord::RecordNotUnique
    reload.copilot_response
  end

  private

  def ensure_account
    self.account_id = copilot_thread&.account_id
  end

  def broadcast_message
    Rails.configuration.dispatcher.dispatch(COPILOT_MESSAGE_CREATED, Time.zone.now, copilot_message: self)
  end

  def validate_message_attributes
    unless message.is_a?(Hash)
      errors.add(:message, 'must be an object')
      return
    end

    validate_message_keys
    validate_message_values
    validate_message_size
  end

  def validate_message_keys
    invalid_keys = message.keys.map(&:to_s) - ALLOWED_MESSAGE_KEYS
    errors.add(:message, "contains invalid attributes: #{invalid_keys.join(', ')}") if invalid_keys.any?
  end

  def validate_message_values
    invalid_value = message.any? do |key, value|
      key = key.to_s
      next !value.is_a?(String) if STRING_MESSAGE_KEYS.include?(key)
      next !value.in?([true, false]) if key == 'reply_suggestion'

      false
    end
    errors.add(:message, 'contains invalid value types') if invalid_value
  end

  def validate_message_size
    errors.add(:message, 'is too large') if message.to_json.bytesize > MESSAGE_BYTES_LIMIT
    errors.add(:message, 'contains an oversized value') if message.values.any? { |value| value.to_s.bytesize > VALUE_BYTES_LIMIT }
  end

  def validate_tenant_context
    validate_conversation_tenant
    validate_source_context
  end

  def validate_conversation_tenant
    return if conversation.blank? || conversation.account_id == account_id

    errors.add(:conversation, 'must belong to the message account')
  end

  def validate_source_context
    return if source_message.blank?

    valid_source = !user? && source_message.account_id == account_id && source_message.copilot_thread_id == copilot_thread_id &&
                   source_message.user?
    errors.add(:source_message, 'must be a user message in the same thread and account') unless valid_source
  end

  def validate_response_workflow
    if response_none?
      errors.add(:response_job_token, 'must be blank without a reservation') if response_job_token.present?
      return
    end

    errors.add(:response_state, 'is only valid for user messages') unless user?
    errors.add(:response_job_token, 'is invalid') unless response_job_token.to_s.match?(RESPONSE_TOKEN_FORMAT)
  end

  def reservable_token?(token)
    candidate = token.to_s
    stored = response_job_token.to_s
    candidate.bytesize == stored.bytesize && stored.present? && ActiveSupport::SecurityUtils.secure_compare(candidate, stored)
  end

  def earlier_response_pending?
    copilot_thread.copilot_messages.user
                  .exists?(id: ...id, response_state: %i[reserved processing])
  end
end
