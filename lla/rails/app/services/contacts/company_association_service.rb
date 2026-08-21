# frozen_string_literal: true

# Tạo/gắn company cho contact theo domain email doanh nghiệp.
#
# Hợp đồng từ spec MIT spec/enterprise/services/contacts/company_association_service_spec.rb
# (đã chuyển sang spec/lla): contact đã có company hoặc thiếu email → nil; email
# nhà cung cấp miễn phí → không tạo; tên công ty ưu tiên
# additional_attributes.company_name contact tự khai, không thì lấy từ domain.
class Contacts::CompanyAssociationService
  def associate_company_from_email(contact)
    return if contact.company_id.present?

    email = contact.email
    return if email.blank?
    return unless Companies::BusinessEmailDetectorService.new(email).perform

    company = find_or_create_company(contact, email.split('@').last.downcase)
    contact.update!(
      company: company,
      additional_attributes: (contact.additional_attributes || {}).merge('company_name' => company.name)
    )
  end

  private

  def find_or_create_company(contact, domain)
    name = contact.additional_attributes&.dig('company_name').presence || domain.split('.').first.capitalize

    contact.account.companies.create_with(name: name).find_or_create_by!(domain: domain)
  end
end
