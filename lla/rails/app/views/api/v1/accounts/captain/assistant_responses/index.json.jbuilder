json.payload do
  json.array! @responses, partial: 'assistant_response', as: :assistant_response
end
json.meta do
  json.total_count @responses_count
  json.page @responses.current_page
end
