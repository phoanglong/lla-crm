# frozen_string_literal: true

class Captain::Tools::Copilot::GetContactService < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  def self.name
    'get_contact'
  end

  description 'Get details of a contact including their profile information'
  param :contact_id, type: :number, desc: 'The ID of the contact to retrieve', required: true

  def execute(contact_id:)
    return 'Contact not found' unless active?

    id = Integer(contact_id, exception: false)
    contact = Contact.find_by(id: id, account_id: assistant.account_id) if id&.positive?
    contact ? bounded_output(contact.to_llm_text) : 'Contact not found'
  end

  def active?
    user_has_permission('contact_manage')
  end
end
