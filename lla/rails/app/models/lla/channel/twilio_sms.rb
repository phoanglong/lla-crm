module Lla::Channel::TwilioSms
  extend ActiveSupport::Concern

  def self.prepended(base)
    base.class_eval do
      encrypts :api_key_secret if Chatwoot.encryption_configured?

      validate :voice_requires_phone_number, if: :voice_enabled?
      after_create_commit :schedule_voice_provisioning, if: :voice_provisioning_required?
      after_update_commit :schedule_voice_lifecycle_change, if: :saved_change_to_voice_enabled?
    end
  end

  def initiate_call(to:, conference_sid: nil, agent_id: nil)
    Voice::Provider::Twilio::Adapter.new(self).initiate_call(
      to: to,
      conference_sid: conference_sid,
      agent_id: agent_id
    )
  end

  def voice_call_webhook_url
    digits = phone_number.delete_prefix('+')
    Rails.application.routes.url_helpers.twilio_voice_call_url(phone: digits)
  end

  def voice_status_webhook_url
    digits = phone_number.delete_prefix('+')
    Rails.application.routes.url_helpers.twilio_voice_status_url(phone: digits)
  end

  def voice_configuration_digest
    Digest::SHA256.hexdigest(
      [account_id, phone_number, account_sid, auth_token, api_key_sid, api_key_secret, voice_enabled?, twiml_app_sid].join(':')
    )
  end

  # Voice channels store the secret in api_key_secret; SMS channels keep using auth_token via super.
  def client
    if api_key_sid.present? && api_key_secret.present?
      Twilio::REST::Client.new(api_key_sid, api_key_secret, account_sid)
    else
      super
    end
  end

  private

  def voice_requires_phone_number
    return if phone_number.present?

    errors.add(:base, 'Voice calling requires a phone number and cannot be used with messaging service SID')
  end

  def voice_provisioning_required?
    voice_enabled? && twiml_app_sid.blank?
  end

  def schedule_voice_lifecycle_change
    action = voice_enabled? ? 'provision' : 'teardown'
    schedule_voice_lifecycle(action)
  end

  def schedule_voice_provisioning
    schedule_voice_lifecycle('provision')
  end

  def schedule_voice_lifecycle(action)
    return if action == 'teardown' && twiml_app_sid.blank?

    Twilio::VoiceLifecycleJob.perform_later(id, action, voice_configuration_digest)
  end
end
