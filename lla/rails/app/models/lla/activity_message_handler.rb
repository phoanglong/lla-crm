# frozen_string_literal: true

# Thông điệp hoạt động khi TRỢ LÝ AI đổi trạng thái hội thoại — chọn khoá i18n
# conversations.activity.captain.* theo lý do/loại lý do đặt qua
# with_captain_activity_context. Prepend qua
# `ActivityMessageHandler.prepend_mod_with('ActivityMessageHandler')` (MIT).
module Lla::ActivityMessageHandler
  private

  def automation_status_change_activity_content
    return super unless Current.executed_by.is_a?(Captain::Assistant)

    captain_status_change_activity_content
  end

  def captain_status_change_activity_content
    return captain_resolved_activity_content if resolved?
    return captain_open_activity_content if open?

    nil
  end

  def captain_resolved_activity_content
    user_name = Current.executed_by.name
    reason = captain_activity_reason

    if reason.present? && captain_activity_reason_type.to_s == 'tool'
      I18n.t('conversations.activity.captain.resolved_by_tool', user_name: user_name, reason: reason)
    elsif reason.present?
      I18n.t('conversations.activity.captain.resolved_with_reason', user_name: user_name, reason: reason)
    else
      I18n.t('conversations.activity.captain.resolved', user_name: user_name)
    end
  end

  def captain_open_activity_content
    user_name = Current.executed_by.name
    reason = captain_activity_reason

    if captain_activity_reason_type.to_s == 'auto_opened_after_agent_reply'
      I18n.t('conversations.activity.captain.auto_opened_after_agent_reply')
    elsif reason.present?
      I18n.t('conversations.activity.captain.open_with_reason', user_name: user_name, reason: reason)
    else
      I18n.t('conversations.activity.captain.open', user_name: user_name)
    end
  end
end
