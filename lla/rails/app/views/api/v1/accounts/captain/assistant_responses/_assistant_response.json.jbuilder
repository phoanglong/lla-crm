json.id assistant_response.id
json.account_id assistant_response.account_id
json.question assistant_response.question
json.answer assistant_response.answer
json.status assistant_response.status
json.created_at assistant_response.created_at.to_i
json.updated_at assistant_response.updated_at.to_i
json.assistant do
  json.partial! 'api/v1/accounts/captain/assistants/assistant', assistant: assistant_response.assistant
end
documentable = assistant_response.documentable
documentable_visible = documentable.present? &&
                       (!documentable.respond_to?(:account_id) || documentable.account_id == assistant_response.account_id)
if documentable_visible
  json.documentable do
    json.id assistant_response.documentable_id
    json.type assistant_response.documentable_type
    if documentable.is_a?(Captain::Document)
      json.name documentable.name
      json.external_link documentable.external_link
    end
  end
end
