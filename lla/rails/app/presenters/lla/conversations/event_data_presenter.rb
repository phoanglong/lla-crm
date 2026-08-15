# frozen_string_literal: true

# Bổ sung dữ liệu SLA vào payload đẩy qua websocket/webhook của hội thoại.
# Prepend qua `Conversations::EventDataPresenter.prepend_mod_with(...)` (MIT).
#
# Hợp đồng từ spec MIT spec/enterprise/presenters/conversations/event_data_presenter_spec.rb
# (đã chuyển sang spec/lla): chỉ khi tài khoản bật feature `sla`; contact bị
# chặn thì trả applied_sla nil, sla_events rỗng và xoá luôn sla_policy_id.
module Lla::Conversations::EventDataPresenter
  def push_data
    data = super
    return data unless account.feature_enabled?('sla')

    if sla_applicable?
      data.merge(applied_sla: applied_sla&.push_event_data, sla_events: sla_events.map(&:push_event_data))
    else
      data.merge(applied_sla: nil, sla_events: [], sla_policy_id: nil)
    end
  end
end
