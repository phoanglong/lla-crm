class Twilio::VoiceTeardownService
  pattr_initialize [:channel!]

  def perform
    clear_number_webhooks
    delete_twiml_app if channel.twiml_app_sid.present?
    clear_voice_credentials
    true
  rescue StandardError => e
    Rails.logger.error(
      "LLA_TWILIO_VOICE_TEARDOWN_FAILED account=#{channel.account_id} channel=#{channel.id} " \
      "error=#{e.class.name} code=#{provider_error_code(e)}"
    )
    raise
  end

  private

  def delete_twiml_app
    channel.client.applications(channel.twiml_app_sid).delete
  end

  def clear_number_webhooks
    numbers = channel.client.incoming_phone_numbers.list(phone_number: channel.phone_number)
    return if numbers.empty?

    channel.client
           .incoming_phone_numbers(numbers.first.sid)
           .update(voice_url: '', status_callback: '')
  end

  def clear_voice_credentials
    channel.update!(twiml_app_sid: nil)
  end

  def provider_error_code(error)
    error.respond_to?(:code) ? error.code.to_s.gsub(/[^A-Za-z0-9_-]/, '').first(40) : 'none'
  end
end
