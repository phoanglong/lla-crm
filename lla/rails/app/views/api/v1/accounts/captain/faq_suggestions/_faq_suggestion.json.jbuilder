json.id faq_suggestion.id
json.account_id faq_suggestion.account_id
json.question faq_suggestion.question
json.answer faq_suggestion.answer
json.status faq_suggestion.status
json.language faq_suggestion.language
json.source_count faq_suggestion.source_count
json.created_at faq_suggestion.created_at.to_i
json.updated_at faq_suggestion.updated_at.to_i
json.assistant do
  json.partial! 'api/v1/accounts/captain/assistants/assistant', assistant: faq_suggestion.assistant
end
