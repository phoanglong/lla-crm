# frozen_string_literal: true

# Controller cha cho tài nguyên lồng trong một company.
class Api::V1::Accounts::Companies::BaseController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_company

  private

  def check_authorization
    authorize(Company)
  end

  def fetch_company
    @company = Current.account.companies.find(params[:company_id])
  end
end
