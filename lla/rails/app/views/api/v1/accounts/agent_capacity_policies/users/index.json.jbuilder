json.array! @users do |user|
  json.partial! 'api/v1/models/capacity_user', formats: [:json], resource: user
end
