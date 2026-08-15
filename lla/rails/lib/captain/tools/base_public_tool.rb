# frozen_string_literal: true

# Lớp nền cho công cụ của trợ lý chạy trong hội thoại với khách (public).
# Không giữ trạng thái thực thi trong instance — mọi thứ đi qua tool_context
# (yêu cầu thread-safety của gem ai-agents).
class Captain::Tools::BasePublicTool < Agents::Tool
  def initialize(assistant)
    @assistant = assistant
    super()
  end

  # Công cụ public luôn sẵn sàng; lớp con có điều kiện riêng thì override.
  def active?
    true
  end

  protected

  attr_reader :assistant

  def find_conversation(state)
    conversation_id = state.dig(:conversation, :id)
    return if conversation_id.blank?

    account_scoped(Conversation).find_by(id: conversation_id)
  end

  def find_contact(state)
    contact_id = state.dig(:contact, :id)
    return if contact_id.blank?

    account_scoped(Contact).find_by(id: contact_id)
  end

  # Mọi truy vấn của công cụ đều bó trong account của trợ lý.
  def account_scoped(model_class)
    model_class.where(account_id: assistant.account_id)
  end

  # Gom metadata dùng chung của một phiên chạy (faq đã tra, ghi chú handoff…)
  # vào state để lớp ghi phiên đọc lại sau.
  def merge_run_metadata(state, key, values)
    state[:cw_metadata] ||= {}
    existing = Array(state[:cw_metadata][key])
    state[:cw_metadata][key] = (existing + Array(values)).uniq
  end

  def set_run_metadata(state, key, value)
    state[:cw_metadata] ||= {}
    state[:cw_metadata][key] = value
  end

  def log_tool_usage(event, payload = {})
    Rails.logger.info("[LLA AI] #{self.class.name} #{event} #{payload.to_json}")
  end
end
