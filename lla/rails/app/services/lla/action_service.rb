# frozen_string_literal: true

# Hành động `add_sla` cho automation rule. Include qua
# `ActionService.include_mod_with('ActionService')` (MIT).
#
# Hợp đồng từ spec MIT spec/enterprise/services/enterprise/action_service_spec.rb
# (đã chuyển sang spec/lla): không ghi đè SLA đang có, không gán cho contact bị
# chặn, id không tồn tại thì thôi.
module Lla::ActionService
  def add_sla(sla_policy_ids)
    sla_policy_id = Array(sla_policy_ids).first
    return if sla_policy_id.blank?
    return if @conversation.sla_policy_id.present?
    return unless @conversation.sla_applicable?

    sla_policy = @account.sla_policies.find_by(id: sla_policy_id)
    return if sla_policy.blank?

    @conversation.update!(sla_policy_id: sla_policy.id)
  end
end
