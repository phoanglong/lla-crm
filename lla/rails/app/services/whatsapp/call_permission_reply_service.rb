# frozen_string_literal: true

class Whatsapp::CallPermissionReplyService
  pattr_initialize [:inbox!, :params!]

  def perform
    return unless inbox.account.feature_enabled?('channel_voice') && inbox.channel.voice_enabled?

    reply_data = extract_reply_data
    return unless reply_data&.dig(:accepted)

    conversation = find_requesting_conversation(reply_data[:context_id], reply_data[:sender_ids])
    return unless conversation

    clear_permission_flag(conversation)
    emit_permission_granted_activity(conversation)
    broadcast_permission_granted(conversation)
  end

  private

  def emit_permission_granted_activity(conversation)
    content = I18n.t(
      'conversations.activity.whatsapp_call.permission_granted',
      contact_name: conversation.contact.name
    )
    ::Conversations::ActivityMessageJob.perform_later(
      conversation,
      { account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity, content: content }
    )
  end

  def extract_reply_data
    message = params.dig(:entry, 0, :changes, 0, :value, :messages, 0)
    reply = message&.dig(:interactive, :call_permission_reply)
    return unless reply

    accepted = reply[:response] == 'accept'
    Rails.logger.info(
      "LLA_WHATSAPP_PERMISSION_REPLY account=#{inbox.account_id} inbox=#{inbox.id} accepted=#{accepted}"
    )
    sender_ids = [message[:from_parent_user_id], message[:from_user_id], message[:from]].compact_blank.map(&:to_s)
    { accepted: accepted, context_id: message.dig(:context, :id), sender_ids: sender_ids }
  end

  def find_requesting_conversation(context_id, sender_ids)
    return if context_id.blank? || context_id.to_s.bytesize > 512

    conversation = inbox.conversations
                        .where.not(status: :resolved)
                        .where("additional_attributes ->> 'call_permission_request_message_id_digest' = ?", digest(context_id))
                        .first
    conversation if conversation && sender_matches?(conversation, sender_ids)
  end

  def sender_matches?(conversation, sender_ids)
    return false if sender_ids.blank?

    known_ids = inbox.contact_inboxes.where(contact_id: conversation.contact_id).pluck(:source_id)
    phone = conversation.contact.phone_number.to_s.delete('+')
    known_ids << phone if phone.present?
    known_ids.map(&:to_s).intersect?(sender_ids)
  end

  def clear_permission_flag(conversation)
    attrs = (conversation.additional_attributes || {}).except(
      'call_permission_requested_at',
      'call_permission_request_message_id',
      'call_permission_request_message_id_digest'
    )
    conversation.update!(additional_attributes: attrs)
  end

  def broadcast_permission_granted(conversation)
    payload = {
      event: 'voice_call.permission_granted',
      data: {
        account_id: inbox.account_id,
        conversation_id: conversation.id,
        contact_name: conversation.contact.name
      }
    }
    permission_streams(conversation).each { |stream| ActionCable.server.broadcast(stream, payload) }
  end

  def permission_streams(conversation)
    assignee_token = conversation.assignee&.pubsub_token
    return [assignee_token] if assignee_token.present?

    online = inbox.available_agents.pluck('users.pubsub_token').compact
    return online if online.present?

    user_ids = inbox.member_ids | inbox.account.administrators.ids
    User.where(id: user_ids).pluck(:pubsub_token).compact
  end

  def digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
