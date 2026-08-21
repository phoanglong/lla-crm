json.payload do
  json.array! @suggestions, partial: 'faq_suggestion', as: :faq_suggestion
end
json.meta do
  json.total_count @suggestions_count
  json.page @current_page.to_i
end
