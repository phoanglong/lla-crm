json.id document.id
json.account_id document.account_id
json.name document.name
json.external_link document.external_link
json.display_url document.display_url
json.pdf_document document.pdf_document?
json.status document.status
json.responses_count document.responses.size
json.content_type document.content_type
json.file_size document.file_size
json.sync_status document.sync_status
json.sync_in_progress document.sync_in_progress?
json.last_sync_error_code document.last_sync_error_code
json.last_synced_at document.last_synced_at&.to_i
json.last_sync_attempted_at document.last_sync_attempted_at&.to_i
json.created_at document.created_at.to_i
json.updated_at document.updated_at.to_i
json.assistant do
  json.partial! 'api/v1/accounts/captain/assistants/assistant', assistant: document.assistant
end
