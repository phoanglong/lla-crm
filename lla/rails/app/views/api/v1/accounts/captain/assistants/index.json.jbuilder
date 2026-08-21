json.payload do
  json.array! @assistants, partial: 'assistant', as: :assistant
end
json.meta do
  json.total_count @assistants_count
  json.page @assistants.current_page
end
