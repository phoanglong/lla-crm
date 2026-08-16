# frozen_string_literal: true

class Whatsapp::IncomingCallBroadcaster
  def initialize(inbox:)
    @inbox = inbox
  end

  def incoming(call, sdp_offer)
    contact = call.contact
    token = call.conversation.assignee&.pubsub_token
    streams = token ? [token] : (online_agent_streams.presence || fallback_agent_streams)
    emit(call, 'voice_call.incoming', streams: streams,
                                      direction: call.direction_label, inbox_id: call.inbox_id,
                                      sdp_offer: sdp_offer, ice_servers: Call.default_ice_servers,
                                      caller: caller_payload(contact))
  end

  def event(call, event, **extra)
    emit(call, event, streams: call_streams(call), **extra)
  end

  private

  attr_reader :inbox

  def emit(call, event, streams:, **extra)
    payload = { event: event, data: base_payload(call).merge(extra) }
    streams.each { |stream| ActionCable.server.broadcast(stream, payload) }
  rescue StandardError => e
    Rails.logger.warn(
      "LLA_WHATSAPP_CALL_BROADCAST_FAILED account=#{call.account_id} inbox=#{call.inbox_id} error=#{e.class.name}"
    )
  end

  def caller_payload(contact)
    { name: contact.name, phone: contact.phone_number, avatar: contact.avatar_url }
  end

  def call_streams(call)
    token = call.accepted_by_agent&.pubsub_token || call.conversation.assignee&.pubsub_token
    token ? [token] : (online_agent_streams.presence || fallback_agent_streams)
  end

  def online_agent_streams
    inbox.available_agents.pluck('users.pubsub_token').compact
  end

  def fallback_agent_streams
    user_ids = inbox.member_ids | inbox.account.administrators.ids
    User.where(id: user_ids).pluck(:pubsub_token).compact
  end

  def base_payload(call)
    { account_id: inbox.account_id, id: call.id, call_id: call.provider_call_id,
      provider: 'whatsapp', conversation_id: call.conversation_id }
  end
end
