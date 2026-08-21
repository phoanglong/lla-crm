# frozen_string_literal: true

class Lla::Voice::InboxConfigurationService
  def initialize(inbox:, user:, params:)
    @inbox = inbox
    @user = user
    @params = params
  end

  def set_inbound_calls!
    validate_admin!
    raise ArgumentError, 'Inbox does not support calling' unless channel.try(:voice_enabled?)

    update_provider_config('inbound_calls_enabled' => boolean_param(:inbound_calls_enabled))
  end

  def set_recording_policy!
    validate_admin!
    raise ArgumentError, 'Inbox does not support recording' unless recording_supported?

    enabled = boolean_param(:voice_recording_enabled)
    version = params[:disclosure_version].to_s.strip
    validate_disclosure_version!(version) if enabled
    update_provider_config(
      'voice_recording_enabled' => enabled,
      'voice_recording_disclosure_version' => enabled ? version : nil
    )
  end

  def set_whatsapp_calling_message!
    validate_admin!
    raise ArgumentError, 'Inbox does not support WhatsApp calling' unless
      channel.is_a?(Channel::Whatsapp) && channel.voice_calling_supported?

    body = params[:call_permission_request_body].to_s.strip
    raise ArgumentError, 'Call permission request message is too long' if body.length > 1024

    update_provider_config('call_permission_request_body' => body.presence)
  end

  private

  attr_reader :inbox, :user, :params

  def validate_admin!
    membership = inbox.account.account_users.find_by(user_id: user.id)
    raise Pundit::NotAuthorizedError unless membership&.administrator? && inbox.account.feature_enabled?('channel_voice')
  end

  def recording_supported?
    channel.try(:voice_enabled?) || (channel.is_a?(Channel::Whatsapp) && channel.voice_calling_supported?)
  end

  def update_provider_config(attributes)
    channel.with_lock do
      channel.provider_config = (channel.provider_config || {}).merge(attributes).compact
      channel.save!(validate: false)
    end
    inbox.update_account_cache
  end

  def validate_disclosure_version!(version)
    return if version.match?(/\A[A-Za-z0-9_.:-]{1,64}\z/)

    raise ArgumentError, 'A valid recording disclosure version is required'
  end

  def boolean_param(name)
    ActiveModel::Type::Boolean.new.cast(params.require(name))
  end

  def channel
    @channel ||= inbox.channel
  end
end
