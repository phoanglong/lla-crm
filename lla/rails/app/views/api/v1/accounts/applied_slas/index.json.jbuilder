json.payload @applied_slas do |applied_sla|
  json.applied_sla applied_sla.push_event_data
  json.conversation Conversations::EventDataPresenter.new(applied_sla.conversation).push_data
end
json.meta do
  json.count @count
end
