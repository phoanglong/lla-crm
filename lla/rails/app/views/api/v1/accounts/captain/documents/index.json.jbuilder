json.payload do
  json.array! @documents, partial: 'document', as: :document
end
json.meta do
  json.total_count @documents_count
  json.page @documents.current_page
end
