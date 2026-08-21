# frozen_string_literal: true

module Lla::Api::V1::Accounts::InboxesController
  def enable_whatsapp_calling
    request_whatsapp_calling(true)
  end

  def disable_whatsapp_calling
    request_whatsapp_calling(false)
  end

  def set_inbound_calls
    voice_configuration_service.set_inbound_calls!
    head :ok
  rescue Pundit::NotAuthorizedError
    raise
  rescue StandardError => e
    render_voice_configuration_error(e)
  end

  def set_voice_recording
    voice_configuration_service.set_recording_policy!
    head :ok
  rescue Pundit::NotAuthorizedError
    raise
  rescue StandardError => e
    render_voice_configuration_error(e)
  end

  def set_whatsapp_calling_message
    voice_configuration_service.set_whatsapp_calling_message!
    head :ok
  rescue Pundit::NotAuthorizedError
    raise
  rescue StandardError => e
    render_voice_configuration_error(e)
  end

  private

  # `auto_assignment_config.max_assignment_limit` is validated by `Lla::Inbox` and
  # enforced by `Lla::Inbox#member_ids_at_max_assignment_limit`, but the request
  # never carried it: the only controller that permitted the parameter was an
  # enterprise extension, so with enterprise off the field was silently dropped by
  # strong parameters and the limit could not be set at all.
  def inbox_attributes
    super + [auto_assignment_config: [:max_assignment_limit]]
  end

  def request_whatsapp_calling(enabled)
    ensure_voice_admin!
    result = Whatsapp::CallingLifecycleRequestService.new(
      inbox: @inbox,
      user: Current.user,
      enabled: enabled,
      idempotency_key: request.headers['Idempotency-Key']
    ).perform
    render json: result, status: :accepted
  rescue Pundit::NotAuthorizedError
    raise
  rescue Whatsapp::CallingLifecycleRequestService::InvalidRequest => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Whatsapp::CallingLifecycleRequestService::IdempotencyConflict => e
    render json: { error: e.message }, status: :conflict
  end

  def ensure_voice_admin!
    raise Pundit::NotAuthorizedError unless Current.account_user&.administrator?
    raise Pundit::NotAuthorizedError unless Current.account.feature_enabled?('channel_voice')
  end

  def render_voice_configuration_error(error)
    Rails.logger.warn(
      "LLA_VOICE_CONFIGURATION_FAILED account=#{Current.account.id} inbox=#{@inbox.id} error=#{error.class.name}"
    )
    render_could_not_create_error('Voice configuration update failed')
  end

  def voice_configuration_service
    Lla::Voice::InboxConfigurationService.new(inbox: @inbox, user: Current.user, params: params)
  end

  def allowed_channel_types
    super + ['voice']
  end

  def channel_type_from_params
    return Channel::TwilioSms if permitted_params[:channel][:type] == 'voice'

    super
  end

  def account_channels_method
    return Current.account.twilio_sms if permitted_params[:channel][:type] == 'voice'

    super
  end

  def create_channel
    return create_voice_channel if permitted_params[:channel][:type] == 'voice'

    super
  end

  def get_channel_attributes(channel_type)
    attrs = super
    return attrs unless channel_type == 'Channel::TwilioSms' && @inbox&.channel&.medium == 'sms'

    attrs + [:voice_enabled, :api_key_sid, :api_key_secret]
  end

  def create_voice_channel
    ensure_voice_admin!
    voice_params = params.require(:channel).permit(
      :phone_number,
      provider_config: %i[account_sid auth_token api_key_sid api_key_secret]
    )
    config = voice_params[:provider_config] || {}
    Current.account.twilio_sms.create!(
      phone_number: voice_params[:phone_number],
      account_sid: config[:account_sid],
      auth_token: config[:auth_token],
      api_key_sid: config[:api_key_sid],
      api_key_secret: config[:api_key_secret],
      medium: :sms,
      voice_enabled: true
    )
  end
end
