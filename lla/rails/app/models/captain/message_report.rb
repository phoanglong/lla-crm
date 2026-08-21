# frozen_string_literal: true

class Captain::MessageReport < ApplicationRecord
  self.table_name = 'captain_message_reports'

  REPORT_REASONS = %w[incorrect_information inappropriate_response incomplete_response outdated_information other].freeze
  MAX_DESCRIPTION_LENGTH = 500
  MAX_DESCRIPTION_INPUT_BYTES = 2_000
  RETENTION_PERIOD = 180.days

  EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  PHONE_PATTERN = %r{(?<!\w)\+?\d[\d .()/\-]{7,}\d(?!\w)}
  SECRET_PATTERNS = [
    %r{\b(?:Bearer\s+)[A-Za-z0-9._~+/\-]+=*}i,
    /\b(?:sk-|ghp_|github_pat_)[A-Za-z0-9_-]{16,}\b/i,
    /-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/mi
  ].freeze

  belongs_to :account
  belongs_to :conversation, class_name: '::Conversation'
  belongs_to :message
  belongs_to :user

  validates :report_reason, presence: true, inclusion: { in: REPORT_REASONS }
  validates :description, length: { maximum: MAX_DESCRIPTION_LENGTH }, allow_nil: true
  validate :description_input_within_limit
  validate :message_contract
  validate :user_membership

  before_validation :derive_tenancy_from_message
  before_validation :normalize_description
  before_validation :set_expiry
  after_commit :instrument_feedback_change, on: %i[create update]

  private

  def derive_tenancy_from_message
    return if message.blank?

    self.account = message.account
    self.conversation = message.conversation
  end

  def normalize_description
    raw = description.to_s
    @description_input_bytes = raw.bytesize
    return self.description = nil if raw.blank?

    normalized = Rails::Html::FullSanitizer.new.sanitize(raw)
    normalized = CGI.unescapeHTML(normalized).squish
    normalized = normalized.gsub(EMAIL_PATTERN, '[REDACTED_EMAIL]')
    normalized = normalized.gsub(PHONE_PATTERN, '[REDACTED_PHONE]')
    SECRET_PATTERNS.each { |pattern| normalized = normalized.gsub(pattern, '[REDACTED_SECRET]') }
    self.description = normalized.presence
  end

  def set_expiry
    self.expires_at ||= (created_at || Time.current) + RETENTION_PERIOD
  end

  def description_input_within_limit
    return unless @description_input_bytes.to_i > MAX_DESCRIPTION_INPUT_BYTES

    errors.add(:description, 'is too large')
  end

  def message_contract
    return if message.blank?

    errors.add(:message, 'must be a public Captain assistant reply') unless public_captain_reply?
    errors.add(:message, 'must belong to its conversation') unless message.conversation&.account_id == message.account_id
  end

  def public_captain_reply?
    message.sender_type == 'Captain::Assistant' && message.outgoing? && !message.private? &&
      message.sender&.account_id == message.account_id
  end

  def user_membership
    return if user.blank? || account.blank?
    return if AccountUser.exists?(account_id: account.id, user_id: user.id)

    errors.add(:user, 'must belong to the report account')
  end

  def instrument_feedback_change
    ActiveSupport::Notifications.instrument(
      'lla.captain.message_feedback',
      account_id: account_id,
      conversation_id: conversation_id,
      message_id: message_id,
      user_id: user_id,
      report_reason: report_reason,
      revised: previous_changes.key?('updated_at') && !previous_changes.key?('id'),
      external_egress: false
    )
  end
end
