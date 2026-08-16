# frozen_string_literal: true

class CopilotMessage < ApplicationRecord
  ALLOWED_MESSAGE_KEYS = %w[content reasoning function_name reply_suggestion].freeze
  MESSAGE_BYTES_LIMIT = 49_152
  VALUE_BYTES_LIMIT = 32_768

  belongs_to :copilot_thread, inverse_of: :copilot_messages
  belongs_to :account

  enum :message_type, { user: 0, assistant: 1, assistant_thinking: 2 }

  validates :message_type, presence: true
  validates :message, presence: true
  before_validation :ensure_account
  validate :validate_message_attributes
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

  # E4d replaces this transitional source-job contract with queue IDs/version
  # only, atomically with the LLA-owned ResponseJob.
  def enqueue_response_job(conversation_id, user_id)
    Captain::Copilot::ResponseJob.perform_later(
      assistant: copilot_thread.assistant,
      conversation_id: conversation_id,
      user_id: user_id,
      copilot_thread_id: copilot_thread.id,
      message: message['content']
    )
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
    invalid_value = message.any? { |key, value| ALLOWED_MESSAGE_KEYS.include?(key.to_s) && !value.is_a?(String) }
    errors.add(:message, 'values must be strings') if invalid_value
  end

  def validate_message_size
    errors.add(:message, 'is too large') if message.to_json.bytesize > MESSAGE_BYTES_LIMIT
    errors.add(:message, 'contains an oversized value') if message.values.any? { |value| value.to_s.bytesize > VALUE_BYTES_LIMIT }
  end
end
