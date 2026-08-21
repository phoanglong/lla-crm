json.partial! 'api/v1/models/contact', formats: [:json], resource: contact
json.company_id contact.company_id
json.linked_to_current_company contact.company_id == @company.id
if contact.company
  json.company do
    json.partial! 'api/v1/models/company', formats: [:json], resource: contact.company
  end
end
