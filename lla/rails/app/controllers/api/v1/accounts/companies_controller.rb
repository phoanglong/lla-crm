# frozen_string_literal: true

# CRUD + tìm kiếm company. Hợp đồng API từ MIT
# app/javascript/dashboard/api/companies.js (payload wrapper, meta total_count +
# page, sort name/contacts_count có tiền tố '-' cho giảm dần).
class Api::V1::Accounts::CompaniesController < Api::V1::Accounts::BaseController
  RESULTS_PER_PAGE = 25
  SORT_COLUMNS = %w[name contacts_count last_activity_at created_at].freeze

  before_action :check_authorization
  before_action :fetch_company, only: [:show, :update, :destroy, :destroy_custom_attributes, :avatar]

  def index
    @companies_count = Current.account.companies.count
    @companies = paginate(Current.account.companies.order(sort_order))
  end

  def search
    return render_could_not_create_error('Specify search string with parameter q') if params[:q].blank?

    scope = Current.account.companies.where('name ILIKE :q OR domain ILIKE :q', q: "%#{params[:q]}%")
    @companies_count = scope.count
    @companies = paginate(scope.order(sort_order))
  end

  def show; end

  def create
    @company = Current.account.companies.new(company_params)
    @company.save!
  end

  def update
    @company.assign_attributes(company_params.except(:custom_attributes))
    @company.custom_attributes = @company.custom_attributes.merge(company_params[:custom_attributes]) if company_params[:custom_attributes]
    @company.save!
  end

  def destroy
    Companies::DeleteJob.perform_later(company_id: @company.id)
    head :ok
  end

  def destroy_custom_attributes
    @company.custom_attributes = @company.custom_attributes.except(*params[:custom_attributes])
    @company.save!
  end

  def avatar
    @company.avatar.purge if @company.avatar.attached?
  end

  private

  def check_authorization
    authorize(Company)
  end

  def fetch_company
    @company = Current.account.companies.find(params[:id])
  end

  def paginate(scope)
    scope.page(params[:page]).per(RESULTS_PER_PAGE)
  end

  # 'name' tăng dần, '-contacts_count' giảm dần — chỉ nhận cột trong danh sách.
  def sort_order
    sort_param = params[:sort].presence || 'name'
    direction = sort_param.start_with?('-') ? :desc : :asc
    column = sort_param.delete_prefix('-')
    column = 'name' unless SORT_COLUMNS.include?(column)

    { column => direction }
  end

  def company_params
    params.require(:company).permit(:name, :domain, :description, :avatar, custom_attributes: {}, additional_attributes: {})
  end
end
