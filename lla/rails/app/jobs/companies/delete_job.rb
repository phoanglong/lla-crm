# frozen_string_literal: true

# Xoá company: gỡ liên kết từng contact trước (để callback dọn
# additional_attributes.company_name) rồi mới xoá bản ghi.
class Companies::DeleteJob < ApplicationJob
  queue_as :low

  def perform(company_id:)
    company = Company.find_by(id: company_id)
    return if company.blank?

    company.contacts.find_each { |contact| contact.update!(company_id: nil) }
    company.destroy!
  end
end
