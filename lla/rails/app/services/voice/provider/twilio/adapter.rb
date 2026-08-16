class Voice::Provider::Twilio::Adapter
  E164_PATTERN = /\A\+[1-9]\d{7,14}\z/

  def initialize(channel)
    @channel = channel
  end

  def initiate_call(to:, conference_sid: nil, agent_id: nil)
    validate_destination!(to)
    call = twilio_client.calls.create(**call_params(to))

    {
      provider: 'twilio',
      call_sid: call.sid,
      status: call.status,
      call_direction: 'outbound',
      requires_agent_join: true,
      agent_id: agent_id,
      conference_sid: conference_sid
    }
  end

  def terminate_call(call_sid)
    raise ArgumentError, 'Invalid Twilio call SID' unless /\ACA[A-Za-z0-9]{4,64}\z/.match?(call_sid.to_s)

    twilio_client.calls(call_sid).update(status: 'completed')
  end

  private

  def call_params(to)
    phone_digits = @channel.phone_number.delete_prefix('+')

    {
      from: @channel.phone_number,
      to: to,
      url: twilio_call_twiml_url(phone_digits),
      status_callback: twilio_call_status_url(phone_digits),
      status_callback_event: %w[
        initiated ringing answered completed failed busy no-answer canceled
      ],
      status_callback_method: 'POST'
    }
  end

  def twilio_call_twiml_url(phone_digits)
    Rails.application.routes.url_helpers.twilio_voice_call_url(phone: phone_digits)
  end

  def twilio_call_status_url(phone_digits)
    Rails.application.routes.url_helpers.twilio_voice_status_url(phone: phone_digits)
  end

  def twilio_client
    @channel.client
  end

  def validate_destination!(destination)
    raise ArgumentError, 'Destination must be an E.164 phone number' unless E164_PATTERN.match?(destination.to_s)
    raise ArgumentError, 'Voice is not enabled' unless @channel.voice_enabled?
  end
end
