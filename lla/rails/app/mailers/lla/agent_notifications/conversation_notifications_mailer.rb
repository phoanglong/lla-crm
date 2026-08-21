# frozen_string_literal: true

# Email báo lỡ hạn SLA. Prepend qua
# `AgentNotifications::ConversationNotificationsMailer.prepend_mod_with(...)` (MIT).
# Template liquid đã có sẵn phía MIT
# (app/views/mailers/agent_notifications/conversation_notifications_mailer/sla_missed_*.liquid);
# dịch vụ Notification::EmailNotificationService gọi các method này với
# (primary_actor, user, secondary_actor) = (conversation, agent, sla_policy).
module Lla::AgentNotifications::ConversationNotificationsMailer
  def sla_missed_first_response(conversation, agent, sla_policy)
    return unless smtp_config_set_or_development?

    subject = "Conversation [ID - #{conversation.display_id}] missed SLA for first response"
    send_sla_notification(conversation, agent, sla_policy, subject)
  end

  def sla_missed_next_response(conversation, agent, sla_policy)
    return unless smtp_config_set_or_development?

    subject = "Conversation [ID - #{conversation.display_id}] missed SLA for next response"
    send_sla_notification(conversation, agent, sla_policy, subject)
  end

  def sla_missed_resolution(conversation, agent, sla_policy)
    return unless smtp_config_set_or_development?

    subject = "Conversation [ID - #{conversation.display_id}] missed SLA for resolution time"
    send_sla_notification(conversation, agent, sla_policy, subject)
  end

  private

  def send_sla_notification(conversation, agent, sla_policy, subject)
    @agent = agent
    @conversation = conversation
    @sla_policy = sla_policy
    @action_url = app_account_conversation_url(account_id: @conversation.account_id, id: @conversation.display_id)
    send_mail_with_liquid(to: @agent.email, subject: subject) and return
  end

  def liquid_droppables
    super.merge({ sla_policy: @sla_policy })
  end
end
