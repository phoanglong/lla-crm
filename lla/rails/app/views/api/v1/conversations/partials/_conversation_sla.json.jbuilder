if conversation.account.feature_enabled?('sla')
  if conversation.sla_applicable?
    json.applied_sla conversation.applied_sla&.push_event_data
    json.sla_events conversation.sla_events.map(&:push_event_data)
  else
    json.applied_sla nil
    json.sla_events []
  end
end
