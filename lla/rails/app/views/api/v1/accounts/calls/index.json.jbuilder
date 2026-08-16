json.meta do
  json.count @calls_count
  json.current_page @calls.current_page
  json.total_pages @calls.total_pages
end

json.payload do
  json.array! @calls do |call|
    json.partial! 'api/v1/models/call', formats: [:json], call: call,
                                                        include_sensitive: @include_sensitive_call_data
  end
end
