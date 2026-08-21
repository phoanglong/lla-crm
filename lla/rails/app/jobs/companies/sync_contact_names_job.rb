# frozen_string_literal: true

# Đồng bộ tên công ty phi chuẩn hoá trong additional_attributes của contact khi
# công ty đổi tên. Đọc tên HIỆN TẠI từ DB (job cũ chạy trễ vẫn ra tên mới nhất)
# và dùng update_column để không đổi updated_at của contact.
class Companies::SyncContactNamesJob < ApplicationJob
  queue_as :low

  def perform(company_id:)
    company = Company.find_by(id: company_id)
    return if company.blank?

    company.contacts.find_each do |contact|
      attributes = (contact.additional_attributes || {}).merge('company_name' => company.name)
      contact.update_column(:additional_attributes, attributes) # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
