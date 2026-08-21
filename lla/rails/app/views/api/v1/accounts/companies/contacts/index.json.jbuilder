json.payload @contacts do |contact|
  json.partial! 'api/v1/accounts/companies/contacts/contact', formats: [:json], contact: contact
end
json.meta do
  json.total_count @contacts_count
  json.page (params[:page].presence || 1).to_i
end
