json.payload @companies do |company|
  json.partial! 'api/v1/models/company', formats: [:json], resource: company
end
json.meta do
  json.total_count @companies_count
  json.page (params[:page].presence || 1).to_i
end
