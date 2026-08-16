json.payload do
  json.array! @copilot_messages do |message|
    json.partial! 'api/v1/models/captain/copilot_message', formats: [:json], resource: message
  end
end

json.meta do
  json.current_page @copilot_messages.current_page
  json.total_pages @copilot_messages.total_pages
end
