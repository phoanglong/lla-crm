# frozen_string_literal: true

class Captain::Tools::Copilot::SearchContactsService < Captain::Tools::BaseTool
  prepend Captain::Tools::Instrumentation

  def self.name
    'search_contacts'
  end

  description 'Search contacts based on query parameters'
  param :email, type: :string, desc: 'Filter contacts by email'
  param :phone_number, type: :string, desc: 'Filter contacts by phone number'
  param :name, type: :string, desc: 'Filter contacts by name (partial match)'

  def execute(email: nil, phone_number: nil, name: nil)
    return 'No contacts found' unless active?
    return 'Please provide a contact search filter' unless meaningful_filter?(email, phone_number, name)

    contacts = filtered_contacts(email: email, phone_number: phone_number, name: name).limit(MAX_RESULT_COUNT).to_a
    return 'No contacts found' if contacts.empty?

    bounded_output(contacts.map(&:to_llm_text).join("\n---\n"))
  end

  def active?
    user_has_permission('contact_manage')
  end

  private

  def meaningful_filter?(email, phone_number, name)
    meaningful_query?(email) || meaningful_query?(phone_number) || meaningful_query?(name)
  end

  def filtered_contacts(email:, phone_number:, name:)
    contacts = Contact.where(account_id: assistant.account_id)
    contacts = contacts.where(email: bounded_query(email)) if meaningful_query?(email)
    contacts = contacts.where(phone_number: bounded_query(phone_number)) if meaningful_query?(phone_number)
    if meaningful_query?(name)
      escaped_name = ActiveRecord::Base.sanitize_sql_like(bounded_query(name))
      contacts = contacts.where('name ILIKE ?', "%#{escaped_name}%")
    end
    contacts.order(updated_at: :desc, id: :desc)
  end
end
