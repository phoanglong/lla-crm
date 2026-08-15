# frozen_string_literal: true

# Gắn/gỡ contact với company. Việc đồng bộ additional_attributes.company_name và
# hoạt động của company do callback trên Contact (Lla::Concerns::Contact) đảm nhiệm.
class Api::V1::Accounts::Companies::ContactsController < Api::V1::Accounts::Companies::BaseController
  RESULTS_PER_PAGE = 25

  def index
    scope = @company.contacts.order(:name)
    @contacts_count = scope.count
    @contacts = scope.page(params[:page]).per(RESULTS_PER_PAGE)
  end

  # Gợi ý contact để gắn thêm: khớp tên nhưng CHƯA thuộc company hiện tại
  # (chưa có company hoặc đang thuộc company khác).
  def search
    scope = Current.account.contacts
                   .where('contacts.name ILIKE :q', q: "%#{params[:q]}%")
                   .where('company_id IS DISTINCT FROM ?', @company.id)
    @contacts_count = scope.count
    @contacts = scope.order(:name).page(params[:page]).per(RESULTS_PER_PAGE)
  end

  def create
    @contact = Current.account.contacts.find(params[:contact_id])
    @contact.update!(company_id: @company.id)
  end

  def destroy
    contact = @company.contacts.find(params[:id])
    contact.update!(company_id: nil)
    head :ok
  end
end
