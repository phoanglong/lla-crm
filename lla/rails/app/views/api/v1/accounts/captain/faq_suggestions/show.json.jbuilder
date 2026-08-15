json.partial! 'faq_suggestion', faq_suggestion: @suggestion
json.observations do
  json.array! @observations do |observation|
    json.id observation.id
    json.generated_question observation.generated_question
    json.generated_answer observation.generated_answer
    json.language observation.language
    json.created_at observation.created_at.to_i
    json.conversation do
      json.id observation.conversation.id
      json.display_id observation.conversation.display_id
    end
  end
end
