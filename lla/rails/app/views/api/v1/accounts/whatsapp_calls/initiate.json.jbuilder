json.status 'calling'
json.call_id @call.provider_call_id
json.id @call.id
json.message_id @message.id
json.conversation_id @conversation.display_id
json.provider 'whatsapp'
recording_enabled = ActiveModel::Type::Boolean.new.cast(@call.inbox.channel.provider_config['voice_recording_enabled']) &&
                    @call.meta['recording_consent_id'].present?
json.recording_enabled recording_enabled
