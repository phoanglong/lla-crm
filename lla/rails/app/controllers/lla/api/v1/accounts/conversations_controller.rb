# frozen_string_literal: true

# Cho PATCH hội thoại nhận sla_policy_id. Prepend qua
# `Api::V1::Accounts::ConversationsController.prepend_mod_with(...)` (MIT).
# Lỗi gán SLA (đã có SLA khác, contact bị chặn…) đi theo đường RecordInvalid
# sẵn có → 422 kèm thông điệp validation.
module Lla::Api::V1::Accounts::ConversationsController
  # Dòng thời gian chỉ số của một hội thoại (first_response, resolution…).
  # Hợp đồng: spec/enterprise/controllers/api/v1/accounts/conversations_controller_spec.rb
  # — trả mảng trực tiếp, sắp theo created_at tăng dần, chỉ của hội thoại này.
  def reporting_events
    render json: @conversation.reporting_events.order(created_at: :asc)
  end

  private

  def permitted_update_params
    super.merge(params.permit(:sla_policy_id))
  end
end
