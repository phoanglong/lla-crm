# frozen_string_literal: true

class Twilio::VoiceLifecycleRepairJob < ApplicationJob
  queue_as :low

  def perform(account_id = nil)
    repair_scope(account_id).find_each do |channel|
      action = channel.voice_enabled? ? 'provision' : 'teardown'
      Twilio::VoiceLifecycleJob.perform_later(channel.id, action, channel.voice_configuration_digest)
    end
  end

  private

  def repair_scope(account_id)
    scope = Channel::TwilioSms.where(voice_enabled: true, twiml_app_sid: nil)
                              .or(Channel::TwilioSms.where(voice_enabled: false).where.not(twiml_app_sid: nil))
    account_id.present? ? scope.where(account_id: account_id) : scope
  end
end
