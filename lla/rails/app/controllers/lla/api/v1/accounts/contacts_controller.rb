# frozen_string_literal: true

# Cho PATCH contact nhận company_id. Prepend qua
# `Api::V1::Accounts::ContactsController.prepend_mod_with(...)` (MIT).
# Đồng bộ additional_attributes.company_name do callback trên Contact đảm nhiệm.
module Lla::Api::V1::Accounts::ContactsController
  private

  def permitted_params
    super.merge(params.permit(:company_id))
  end
end
