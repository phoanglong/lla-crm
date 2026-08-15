json.payload do
  json.array! @suggestions, partial: 'faq_suggestion', as: :faq_suggestion
end
json.meta do
  json.total_count @suggestions_count
  json.page @suggestions.current_page
end
