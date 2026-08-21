contact = call.conversation&.contact

json.id call.id
json.call_id call.provider_call_id
json.provider call.provider
json.status call.display_status
json.direction call.direction_label
json.conversation_id call.conversation_id
json.inbox_id call.inbox_id
json.message_id call.message_id
json.accepted_by_agent_id call.accepted_by_agent_id
json.elapsed_seconds(call.started_at ? (Time.current - call.started_at).to_i : 0)
json.sdp_offer Lla::Voice::SdpStore.read(call: call, kind: 'offer')
json.ice_servers Call.default_ice_servers
recording_enabled = ActiveModel::Type::Boolean.new.cast(call.inbox.channel.provider_config['voice_recording_enabled']) &&
                    call.meta['recording_consent_id'].present?
json.recording_enabled recording_enabled

if contact
  json.caller do
    json.name contact.name
    json.phone contact.phone_number
    json.avatar contact.avatar_url
  end
else
  json.caller({})
end
