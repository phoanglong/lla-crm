# frozen_string_literal: true

# Cho PATCH hội thoại nhận sla_policy_id. Prepend qua
# `Api::V1::Accounts::ConversationsController.prepend_mod_with(...)` (MIT).
# Lỗi gán SLA (đã có SLA khác, contact bị chặn…) đi theo đường RecordInvalid
# sẵn có → 422 kèm thông điệp validation.
module Lla::Api::V1::Accounts::ConversationsController
  # Dòng thời gian chỉ số của một hội thoại (first_response, resolution…).
  # Hợp đồng: spec/enterprise/controllers/api/v1/accounts/conversations_controller_spec.rb
  # — trả mảng trực tiếp, sắp theo created_at tăng dần, chỉ của hội thoại này.
  # Rendered through an explicit partial rather than `render json:` of the model.
  # The raw form emitted every column of `reporting_events`, so anything added to
  # that table later would have appeared in the API without a decision, and the
  # ordering was not total — two events written in the same tick could come back in
  # either order between requests.
  def reporting_events
    @reporting_events = @conversation.reporting_events.order(created_at: :asc, id: :asc)
    render 'lla/api/v1/accounts/conversations/reporting_events', formats: [:json]
  end

  private

  def permitted_update_params
    super.merge(params.permit(:sla_policy_id))
  end
end
