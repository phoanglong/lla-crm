json.id call.id
json.call_id call.provider_call_id if include_sensitive
json.provider call.provider
json.status call.display_status
json.direction call.direction_label
json.duration_seconds call.duration_seconds
json.end_reason call.end_reason
json.started_at call.started_at&.to_i
json.ended_at call.ended_at&.to_i
json.created_at call.created_at.to_i
json.message_id call.message_id
json.has_recording call.recording.attached?
json.has_transcript call.transcript.present?

if include_sensitive
  json.recording_url call.recording_url
  json.transcript call.transcript
end

json.conversation do
  json.id call.conversation_id
  json.display_id call.conversation.display_id
end

json.inbox do
  json.id call.inbox_id
  json.name call.inbox.name
  json.channel_type call.inbox.channel_type
  json.medium call.inbox.channel.try(:medium)
end

if call.accepted_by_agent
  json.agent do
    json.id call.accepted_by_agent.id
    json.name call.accepted_by_agent.available_name
    json.avatar call.accepted_by_agent.avatar_url
  end
else
  json.agent nil
end

json.contact do
  json.id call.contact.id
  json.name call.contact.name
  json.phone_number call.contact.phone_number if include_sensitive
  json.avatar call.contact.avatar_url
end
