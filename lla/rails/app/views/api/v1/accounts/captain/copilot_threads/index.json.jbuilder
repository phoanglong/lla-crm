json.payload do
  json.array! @copilot_threads do |thread|
    json.partial! 'api/v1/models/captain/copilot_thread', resource: thread
  end
end

json.meta do
  json.current_page @copilot_threads.current_page
  json.total_pages @copilot_threads.total_pages
end
