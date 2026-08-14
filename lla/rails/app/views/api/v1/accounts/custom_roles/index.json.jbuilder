json.array! @custom_roles do |custom_role|
  json.partial! 'api/v1/models/custom_role', formats: [:json], resource: custom_role
end
