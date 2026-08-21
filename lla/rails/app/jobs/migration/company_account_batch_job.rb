# frozen_string_literal: true

# Gắn company cho toàn bộ contact chưa có company của một tài khoản, theo cùng
# quy tắc email doanh nghiệp của Contacts::CompanyAssociationService.
class Migration::CompanyAccountBatchJob < ApplicationJob
  queue_as :low

  def perform(account)
    service = Contacts::CompanyAssociationService.new

    account.contacts.where(company_id: nil).where.not(email: [nil, '']).find_each(batch_size: 500) do |contact|
      service.associate_company_from_email(contact)
    end
  end
end
