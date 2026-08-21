# frozen_string_literal: true

module Captain::Assistant::RunnerStateHelper
  CONVERSATION_STATE_ATTRIBUTES = %i[id display_id inbox_id contact_id status priority].freeze
  CONTACT_STATE_ATTRIBUTES = %i[id name contact_type].freeze
  CONTACT_INBOX_STATE_ATTRIBUTES = %i[id hmac_verified].freeze
  CAMPAIGN_STATE_ATTRIBUTES = %i[id title campaign_type description message].freeze
  STATE_STRING_BYTES = 2_048

  private

  def build_state
    state = {
      account_id: @assistant.account_id,
      assistant_id: @assistant.id,
      timezone: @conversation&.inbox&.timezone.presence || 'UTC'
    }
    state[:source] = @source if @source.present?

    build_conversation_state(state) if @conversation
    state
  end

  def build_conversation_state(state)
    state[:conversation] = slice_attrs(@conversation, CONVERSATION_STATE_ATTRIBUTES)
    state[:channel_type] = @conversation.inbox&.channel_type.to_s.byteslice(0, 120)
    state[:contact] = slice_attrs(@conversation.contact, CONTACT_STATE_ATTRIBUTES) if @conversation.contact
    state[:campaign] = slice_attrs(@conversation.campaign, CAMPAIGN_STATE_ATTRIBUTES) if @conversation.campaign
    state[:contact_inbox] = slice_attrs(@conversation.contact_inbox, CONTACT_INBOX_STATE_ATTRIBUTES) if @conversation.contact_inbox
  end

  def slice_attrs(record, keys)
    record.attributes.symbolize_keys.slice(*keys).transform_values do |value|
      value.is_a?(String) ? value.byteslice(0, STATE_STRING_BYTES).to_s.scrub : value
    end
  end
end
