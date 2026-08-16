class Twilio::VoiceWebhookSetupService
  include Rails.application.routes.url_helpers

  pattr_initialize [:channel!]

  HTTP_METHOD = 'POST'.freeze

  # Returns created TwiML App SID on success.
  def perform
    validate_token_credentials!

    @created_app_sid = create_twiml_app!
    configure_number_webhooks!
    @created_app_sid
  rescue StandardError => e
    compensate_created_app
    log_twilio_error('PROVISION', e)
    raise
  end

  private

  def validate_token_credentials!
    channel.client.incoming_phone_numbers.list(limit: 1)
  end

  def create_twiml_app!
    friendly_name = "LLA Voice channel #{channel.id || 'new'}"
    app = channel.client.applications.create(
      friendly_name: friendly_name,
      voice_url: channel.voice_call_webhook_url,
      voice_method: HTTP_METHOD
    )
    app.sid
  end

  def configure_number_webhooks!
    numbers = channel.client.incoming_phone_numbers.list(phone_number: channel.phone_number)
    raise 'Configured Twilio phone number was not found' if numbers.empty?

    channel.client
           .incoming_phone_numbers(numbers.first.sid)
           .update(
             voice_url: channel.voice_call_webhook_url,
             voice_method: HTTP_METHOD,
             status_callback: channel.voice_status_webhook_url,
             status_callback_method: HTTP_METHOD
           )
  end

  def log_twilio_error(context, error)
    Rails.logger.error(
      "LLA_TWILIO_VOICE_SETUP_FAILED context=#{context} account=#{channel.account_id} " \
      "channel=#{channel.id || 'new'} error=#{error.class.name} code=#{provider_error_code(error)}"
    )
  end

  def compensate_created_app
    return if @created_app_sid.blank?

    channel.client.applications(@created_app_sid).delete
  rescue StandardError => e
    log_twilio_error('COMPENSATE_APP', e)
  end

  def provider_error_code(error)
    error.respond_to?(:code) ? error.code.to_s.gsub(/[^A-Za-z0-9_-]/, '').first(40) : 'none'
  end
end
