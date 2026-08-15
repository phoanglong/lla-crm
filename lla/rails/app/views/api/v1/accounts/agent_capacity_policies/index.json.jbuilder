json.array! @agent_capacity_policies do |policy|
  json.partial! 'api/v1/models/agent_capacity_policy', formats: [:json], resource: policy
end
