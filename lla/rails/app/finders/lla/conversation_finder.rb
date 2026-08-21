# frozen_string_literal: true

# Preload the SLA associations when the account has SLAs, so rendering a page of
# conversations does not issue a query per conversation. Behaviour identical to the
# enterprise extension it replaces; it is here so it survives with enterprise off.
module Lla::ConversationFinder
  def conversations_base_query
    return super unless current_account.feature_enabled?('sla')

    super.includes(:applied_sla, :sla_events, inbox: :working_hours)
  end
end
