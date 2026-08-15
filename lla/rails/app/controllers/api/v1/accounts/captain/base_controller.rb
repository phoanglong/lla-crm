# frozen_string_literal: true

# Nền chung cho API captain: phân trang 25 bản ghi/trang, khoá `payload` +
# `meta` (hợp đồng từ app/javascript/dashboard/api/captain/*).
class Api::V1::Accounts::Captain::BaseController < Api::V1::Accounts::BaseController
  RESULTS_PER_PAGE = 25

  private

  def current_page
    (params[:page].presence || 1).to_i
  end

  def paginate(scope)
    scope.page(current_page).per(RESULTS_PER_PAGE)
  end
end
