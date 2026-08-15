json.payload @sla_policies do |sla_policy|
  json.partial! 'api/v1/models/sla_policy', formats: [:json], resource: sla_policy
end
