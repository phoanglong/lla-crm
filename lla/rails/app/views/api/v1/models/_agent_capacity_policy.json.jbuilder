json.id resource.id
json.name resource.name
json.description resource.description
json.exclusion_rules resource.exclusion_rules
json.account_id resource.account_id
json.assigned_agent_count resource.account_users.size
json.inbox_capacity_limits resource.inbox_capacity_limits do |limit|
  json.partial! 'api/v1/models/inbox_capacity_limit', formats: [:json], resource: limit
end
json.created_at resource.created_at
json.updated_at resource.updated_at
