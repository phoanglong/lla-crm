# frozen_string_literal: true

# Cho automation rule dùng SLA: điều kiện theo sla_policy_id và hành động add_sla.
# Prepend qua `AutomationRule.prepend_mod_with('AutomationRule')` (MIT).
module Lla::AutomationRule
  def conditions_attributes
    super + ['sla_policy_id']
  end

  def actions_attributes
    super + ['add_sla']
  end
end
