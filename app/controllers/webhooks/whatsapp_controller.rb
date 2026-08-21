class Webhooks::WhatsappController < ActionController::API
  include MetaTokenVerifyConcern

  before_action :verify_meta_signature!, only: :process_payload
  before_action :claim_lla_voice_event!, only: :process_payload

  def process_payload
    if inactive_whatsapp_number?
      Rails.logger.warn("Rejected webhook for inactive WhatsApp number: #{params[:phone_number]}")
      render json: { error: 'Inactive WhatsApp number' }, status: :unprocessable_entity
      return
    end

    if @lla_voice_event
      return head :ok if @lla_voice_duplicate

      routing = lla_voice_routing_params
      encrypted_payload = Lla::Voice::PayloadCipher.encrypt(params.to_unsafe_hash)
      Webhooks::WhatsappEventsJob.perform_later(routing, @lla_voice_event.id, encrypted_payload)
    else
      Webhooks::WhatsappEventsJob.perform_later(params.to_unsafe_hash)
    end
    head :ok
  end

  private

  def valid_token?(token)
    channel = Channel::Whatsapp.find_by(phone_number: params[:phone_number])
    whatsapp_webhook_verify_token = channel.provider_config['webhook_verify_token'] if channel.present?
    token == whatsapp_webhook_verify_token if whatsapp_webhook_verify_token.present?
  end

  # Kênh mang app secret của chính tenant thì **chỉ** chữ ký của app đó được chấp nhận. Nếu
  # vẫn nhận thêm secret của bản cài đặt thì một tenant tự mang app vẫn tin vào chữ ký do
  # ứng dụng của LLA ký — đúng cái ranh giới mà việc tự mang app dựng lên.
  def meta_app_secrets
    channel_secrets = channel_meta_app_secrets(whatsapp_channel)
    return channel_secrets if channel_secrets.present?

    [GlobalConfigService.load('WHATSAPP_APP_SECRET', nil)]
  end

  def whatsapp_channel
    @whatsapp_channel ||= whatsapp_business_payload_channel || Channel::Whatsapp.find_by(phone_number: params[:phone_number])
  end

  def meta_signature_verification_required?
    return true if lla_voice_event?
    return true if whatsapp_channel.blank?
    return false unless whatsapp_channel.provider == 'whatsapp_cloud'
    return true if channel_meta_app_secrets(whatsapp_channel).present?

    whatsapp_channel.provider_config['source'] == 'embedded_signup'
  end

  def claim_lla_voice_event!
    return unless lla_voice_event?
    return if inactive_whatsapp_number?
    raise ActiveRecord::RecordNotFound if whatsapp_channel.blank?

    @lla_voice_event, @lla_voice_duplicate = Lla::Voice::WhatsappEventClaim.new(
      request: request,
      channel: whatsapp_channel
    ).claim!
  end

  def lla_voice_event?
    field = params.dig(:entry, 0, :changes, 0, :field)
    permission_type = params.dig(:entry, 0, :changes, 0, :value, :messages, 0, :interactive, :type)
    field == 'calls' || permission_type == 'call_permission_reply'
  end

  def lla_voice_routing_params
    phone_number_id = params.dig(:entry, 0, :changes, 0, :value, :metadata, :phone_number_id)
    {
      object: params[:object],
      entry: [{ changes: [{ value: { metadata: { phone_number_id: phone_number_id } } }] }]
    }
  end

  def whatsapp_business_payload_channel
    return unless params[:object] == 'whatsapp_business_account'

    metadata = params.dig(:entry, 0, :changes, 0, :value, :metadata)
    return if metadata.blank?

    Whatsapp::WebhookChannelFinderService.new(
      display_phone_number: metadata[:display_phone_number],
      phone_number_id: metadata[:phone_number_id]
    ).perform
  end

  def inactive_whatsapp_number?
    phone_number = params[:phone_number]
    return false if phone_number.blank?

    inactive_numbers = GlobalConfig.get_value('INACTIVE_WHATSAPP_NUMBERS').to_s
    return false if inactive_numbers.blank?

    inactive_numbers_array = inactive_numbers.split(',').map(&:strip)
    inactive_numbers_array.include?(phone_number)
  end
end
