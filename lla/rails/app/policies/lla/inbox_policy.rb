# frozen_string_literal: true

module Lla::InboxPolicy
  def enable_whatsapp_calling? = @account_user.administrator?
  def disable_whatsapp_calling? = @account_user.administrator?
  def set_inbound_calls? = @account_user.administrator?
  def set_voice_recording? = @account_user.administrator?
  def set_whatsapp_calling_message? = @account_user.administrator?
end
