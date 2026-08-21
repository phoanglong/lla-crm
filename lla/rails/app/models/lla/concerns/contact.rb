# frozen_string_literal: true

# Gắn contact vào company. Include qua `Contact.include_mod_with('Concerns::Contact')`
# (MIT app/models/contact.rb). MIT push_event_data đã tự thêm company_id khi
# feature `companies` bật.
#
# Hợp đồng từ spec MIT (đã chuyển sang spec/lla): tự tạo/gắn company theo domain
# email doanh nghiệp khi feature bật; đồng bộ additional_attributes.company_name
# khi gắn/gỡ; đẩy hoạt động của contact lên company.
module Lla::Concerns::Contact
  extend ActiveSupport::Concern

  included do
    belongs_to :company, optional: true, counter_cache: true

    after_save :sync_company_name_attribute, if: :saved_change_to_company_id?
    after_save :sync_company_activity, if: :saved_change_to_last_activity_at?
    after_commit :auto_associate_company, on: [:create, :update]
  end

  private

  # update_column: đây là đồng bộ dữ liệu phi chuẩn hoá, không phải người dùng
  # sửa contact — không chạy lại callback, không đổi updated_at.
  def sync_company_name_attribute
    attributes = additional_attributes || {}
    if company_id.present?
      attributes = attributes.merge('company_name' => company.name)
      company.record_activity_at!(last_activity_at)
    else
      attributes = attributes.except('company_name')
    end

    self.additional_attributes = attributes
    update_column(:additional_attributes, attributes) # rubocop:disable Rails/SkipsModelValidations
  end

  def sync_company_activity
    company&.record_activity_at!(last_activity_at)
  end

  def auto_associate_company
    return unless account.feature_enabled?('companies')
    return if company_id.present?
    return if email.blank?
    return unless saved_change_to_email?

    Contacts::CompanyAssociationService.new.associate_company_from_email(self)
  end
end
