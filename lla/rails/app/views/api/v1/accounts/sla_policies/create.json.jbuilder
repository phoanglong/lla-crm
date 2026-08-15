json.payload do
  json.partial! 'api/v1/models/sla_policy', formats: [:json], resource: @sla_policy
end
