class Voice::Provider::Twilio::TokenService
  TOKEN_TTL = 5.minutes.to_i

  pattr_initialize [:inbox!, :user!, :account!]

  def generate
    validate_context!

    {
      token: access_token.to_jwt,
      identity: identity,
      voice_enabled: true,
      agent_id: user.id,
      account_id: account.id,
      inbox_id: inbox.id,
      has_twiml_app: channel.twiml_app_sid.present?
    }
  end

  private

  def channel
    @channel ||= inbox.channel
  end

  def identity
    @identity ||= "agent-#{user.id}-account-#{account.id}"
  end

  def access_token
    Twilio::JWT::AccessToken.new(
      channel.account_sid,
      channel.api_key_sid,
      channel.api_key_secret,
      identity: identity,
      ttl: TOKEN_TTL
    ).tap { |token| token.add_grant(voice_grant) }
  end

  def voice_grant
    Twilio::JWT::AccessToken::VoiceGrant.new.tap do |grant|
      grant.incoming_allow = true
      grant.outgoing_application_sid = channel.twiml_app_sid
      grant.outgoing_application_params = outgoing_params
    end
  end

  def outgoing_params
    {
      account_id: account.id,
      agent_id: user.id,
      identity: identity,
      client_name: identity,
      accountSid: channel.account_sid,
      is_agent: 'true'
    }
  end

  def validate_context!
    raise ArgumentError, 'Inbox does not belong to account' unless inbox.account_id == account.id
    raise Pundit::NotAuthorizedError unless authorized_user?

    validate_channel!
  end

  def authorized_user?
    membership = account.account_users.find_by(user_id: user.id)
    membership&.administrator? || inbox.members.exists?(id: user.id)
  end

  def validate_channel!
    raise ArgumentError, 'Unsupported voice channel' unless channel.is_a?(Channel::TwilioSms)
    raise ArgumentError, 'Voice is not enabled' unless account.feature_enabled?('channel_voice') && channel.voice_enabled?

    required_credentials = [channel.account_sid, channel.api_key_sid, channel.api_key_secret, channel.twiml_app_sid]
    raise ArgumentError, 'Voice credentials are incomplete' if required_credentials.any?(&:blank?)
  end
end
