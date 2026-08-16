json.id assistant.id
json.account_id assistant.account_id
json.name assistant.name
json.description assistant.description
if Current.account_user&.administrator?
  json.config assistant.config
  json.response_guidelines assistant.response_guidelines
  json.guardrails assistant.guardrails
else
  json.config assistant.config.to_h.slice('product_name', 'feature_faq', 'feature_memory', 'feature_citation', 'feature_contact_attributes')
end
json.created_at assistant.created_at.to_i
json.updated_at assistant.updated_at.to_i
