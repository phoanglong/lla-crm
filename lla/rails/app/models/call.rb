# frozen_string_literal: true

class Call < ApplicationRecord
  STATUSES = %w[ringing in_progress completed no_answer failed rejected].freeze
  TERMINAL_STATUSES = %w[completed no_answer failed rejected].freeze
  TRANSITIONS = {
    'ringing' => %w[in_progress completed no_answer failed rejected],
    'in_progress' => TERMINAL_STATUSES
  }.freeze
  DISPLAY_DIRECTION = { 'incoming' => 'inbound', 'outgoing' => 'outbound' }.freeze
  DEFAULT_STUN_URL = 'stun:stun.l.google.com:19302'
  ICE_URL_PATTERN = /\A(?:stun|turn|turns):[^\s@]+\z/

  store_accessor :meta, :conference_sid, :twilio_conference_sid, :recording_sid, :parent_call_sid, :initiated_at

  enum :provider, { twilio: 0, whatsapp: 1 }
  enum :direction, { incoming: 0, outgoing: 1 }

  belongs_to :account
  belongs_to :inbox
  belongs_to :conversation
  belongs_to :contact
  belongs_to :message, optional: true, inverse_of: :call
  belongs_to :accepted_by_agent, class_name: 'User', optional: true

  has_many :lla_call_events, class_name: 'Lla::Voice::CallEvent', dependent: :delete_all, inverse_of: :call
  has_many :lla_call_operations, class_name: 'Lla::Voice::CallOperation', dependent: :delete_all, inverse_of: :call
  has_one_attached :recording

  validates :provider_call_id, presence: true, length: { maximum: 255 },
                               uniqueness: { scope: %i[account_id inbox_id provider] }
  validates :provider, :direction, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :duration_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validate :associations_share_tenant

  scope :active, -> { where.not(status: TERMINAL_STATUSES) }
  scope :by_conference_sid, ->(sid) { where("meta->>'conference_sid' = ?", sid) }
  scope :by_twilio_conference_sid, ->(sid) { where("meta->>'twilio_conference_sid' = ?", sid) }

  def self.find_by_provider_call_id(account:, inbox:, provider:, provider_call_id:)
    where(account_id: account.id, inbox_id: inbox.id).find_by(provider: provider, provider_call_id: provider_call_id)
  end

  def self.default_ice_servers
    urls = ENV.fetch('VOICE_CALL_STUN_URLS', DEFAULT_STUN_URL).split(',').filter_map do |candidate|
      candidate = candidate.strip
      candidate if ICE_URL_PATTERN.match?(candidate)
    end
    urls = [DEFAULT_STUN_URL] if urls.empty?
    [{ urls: urls }]
  end

  def default_conference_sid
    "conf_account_#{account_id}_call_#{id}"
  end

  def direction_label
    DISPLAY_DIRECTION[direction]
  end

  def self.direction_from_label(value)
    DISPLAY_DIRECTION.key(value) || value
  end

  def self.status_from_display(value)
    value.to_s.tr('-', '_')
  end

  def ringing?
    status == 'ringing'
  end

  def in_progress?
    status == 'in_progress'
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def display_status
    status.to_s.tr('_', '-')
  end

  # Wave F3 removes the legacy provider services that wrote this timestamp to
  # meta. Until then, keep existing records and in-flight callbacks readable.
  def ended_at
    self[:ended_at] || legacy_ended_at
  end

  def recording_url(expires_in: 5.minutes)
    return unless recording.attached?

    signed_blob_id = recording.blob.signed_id(expires_in: expires_in, purpose: :blob_id)
    Rails.application.routes.url_helpers.rails_service_blob_url(signed_blob_id, recording.filename)
  end

  # Returns :applied, :duplicate or :stale. The row lock and lock_version make
  # concurrent provider/human events converge on one monotonic state.
  def transition_to!(target_status, occurred_at: Time.current, duration_seconds: nil, end_reason: nil)
    target_status = target_status.to_s
    raise ArgumentError, 'invalid call status' unless STATUSES.include?(target_status)

    with_lock do
      if status == target_status
        preserve_earliest_start!(occurred_at) if target_status == 'in_progress'
        next :duplicate
      end
      next :stale unless TRANSITIONS.fetch(status, []).include?(target_status)

      update!(transition_attributes(target_status, occurred_at, duration_seconds, end_reason))
      :applied
    end
  end

  # Event payload deliberately excludes phone, transcript, recording URL, SDP
  # and provider credentials. Authorized APIs may expose additional fields.
  def push_event_data
    {
      id: id,
      provider_call_id: provider_call_id,
      provider: provider,
      direction: direction_label,
      status: display_status,
      duration_seconds: duration_seconds,
      end_reason: end_reason,
      accepted_by_agent_id: accepted_by_agent_id,
      accepted_by_agent_name: accepted_by_agent&.available_name,
      started_at: started_at&.to_i,
      ended_at: ended_at&.to_i
    }
  end

  private

  def transition_attributes(target_status, occurred_at, supplied_duration, supplied_reason)
    timestamp = occurred_at.respond_to?(:to_time) ? occurred_at.to_time : Time.zone.at(occurred_at.to_i)
    attrs = { status: target_status }
    attrs[:started_at] = timestamp if target_status == 'in_progress' && (started_at.nil? || timestamp < started_at)
    if TERMINAL_STATUSES.include?(target_status)
      attrs[:ended_at] = timestamp
      attrs[:duration_seconds] = resolved_duration(supplied_duration, timestamp)
      attrs[:end_reason] = supplied_reason if supplied_reason.present?
    end
    attrs
  end

  def preserve_earliest_start!(occurred_at)
    timestamp = occurred_at.respond_to?(:to_time) ? occurred_at.to_time : Time.zone.at(occurred_at.to_i)
    update!(started_at: timestamp) if started_at.nil? || timestamp < started_at
  end

  def resolved_duration(supplied_duration, timestamp)
    return supplied_duration.to_i if supplied_duration.present?
    return unless started_at

    [(timestamp - started_at).to_i, 0].max
  end

  def legacy_ended_at
    timestamp = meta&.dig('ended_at')
    numeric_timestamp = Float(timestamp, exception: false)
    Time.zone.at(numeric_timestamp) if numeric_timestamp&.positive?
  end

  def associations_share_tenant
    validate_account_reference(inbox, :inbox)
    validate_account_reference(conversation, :conversation)
    validate_account_reference(contact, :contact)
    validate_message_reference
    validate_conversation_references
    validate_agent_membership
  end

  def validate_account_reference(record, attribute)
    return if record.blank? || account_id.blank? || record.account_id == account_id

    errors.add(attribute, 'must belong to the call account')
  end

  def validate_message_reference
    return if message.blank?

    errors.add(:message, 'must belong to the call conversation') unless
      message.account_id == account_id && message.conversation_id == conversation_id
  end

  def validate_conversation_references
    return if conversation.blank?

    errors.add(:conversation, 'must belong to the call inbox') unless conversation.inbox_id == inbox_id
    errors.add(:conversation, 'must belong to the call contact') unless conversation.contact_id == contact_id
  end

  def validate_agent_membership
    return if accepted_by_agent_id.blank? || account_id.blank?
    return if AccountUser.exists?(account_id: account_id, user_id: accepted_by_agent_id)

    errors.add(:accepted_by_agent, 'must belong to the call account')
  end
end
