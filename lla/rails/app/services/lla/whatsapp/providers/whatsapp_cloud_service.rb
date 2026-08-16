module Lla::Whatsapp::Providers::WhatsappCloudService
  # Calls API + the call_permission_request interactive message both require Graph
  # API v17+; OSS phone_id_path is locked at v13.0 for legacy /messages compatibility.
  # Use the configured global version (defaulting to v22.0) for call-flow endpoints.
  WHATSAPP_CALLING_API_VERSION_FALLBACK = 'v22.0'.freeze

  def pre_accept_call(call_id, sdp_answer)
    call_api('pre_accept_call', call_action_body(call_id, 'pre_accept', sdp_answer))
  end

  def accept_call(call_id, sdp_answer)
    call_api('accept_call', call_action_body(call_id, 'accept', sdp_answer))
  end

  def reject_call(call_id) = call_api('reject_call', call_action_body(call_id, 'reject'))

  def terminate_call(call_id) = call_api('terminate_call', call_action_body(call_id, 'terminate'))

  def send_call_permission_request(to_phone_number, body_text = I18n.t('conversations.messages.whatsapp.call_permission_request_body'))
    Lla::Whatsapp::Providers::CallingRequestValidator.validate_destination!(to_phone_number)
    raise ArgumentError, 'Permission request body is too large' if body_text.to_s.bytesize > 1024

    response = HTTParty.post(
      "#{calls_phone_id_path}/messages", headers: api_headers, body: permission_request_body(to_phone_number, body_text), timeout: 10
    )

    unless response.success?
      log_provider_failure('permission_request', response)
      return nil
    end

    response.parsed_response
  end

  def initiate_call(to_phone_number, sdp_offer)
    Lla::Whatsapp::Providers::CallingRequestValidator.validate_destination!(to_phone_number)
    Lla::Voice::SdpStore.validate!('offer', sdp_offer)
    response = HTTParty.post(
      "#{calls_phone_id_path}/calls", headers: api_headers, body: initiate_call_body(to_phone_number, sdp_offer), timeout: 10
    )
    process_initiate_call_response(response)
  end

  # Sets WABA calling status ('ENABLED'/'DISABLED'). Returns true or a stable
  # LLA-owned error; provider response bodies are never surfaced to clients.
  def update_calling_status(status)
    raise ArgumentError, 'Invalid WhatsApp calling status' unless %w[ENABLED DISABLED].include?(status)

    response = HTTParty.post(
      "#{calls_phone_id_path}/settings",
      headers: api_headers,
      body: { calling: { status: status } }.to_json,
      timeout: 10
    )
    return true if response.success?

    log_provider_failure('calling_status', response)
    raise 'WhatsApp calling status update failed'
  end

  private

  def calls_phone_id_path
    base = ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
    version = GlobalConfigService.load('WHATSAPP_API_VERSION', WHATSAPP_CALLING_API_VERSION_FALLBACK)
    phone_number_id = whatsapp_channel.provider_config['phone_number_id'].to_s
    Lla::Whatsapp::Providers::CallingRequestValidator.validate_base!(base)
    Lla::Whatsapp::Providers::CallingRequestValidator.validate_api_version!(version)
    Lla::Whatsapp::Providers::CallingRequestValidator.validate_phone_number_id!(phone_number_id)

    "#{base.delete_suffix('/')}/#{version}/#{phone_number_id}"
  end

  def call_action_body(call_id, action, sdp_answer = nil)
    Lla::Whatsapp::Providers::CallingRequestValidator.validate_call_id!(call_id)
    Lla::Voice::SdpStore.validate!('answer', sdp_answer) if sdp_answer
    body = { messaging_product: 'whatsapp', call_id: call_id, action: action }
    body[:session] = { sdp: sdp_answer, sdp_type: 'answer' } if sdp_answer
    body
  end

  def call_api(action_name, body)
    url = "#{calls_phone_id_path}/calls"
    response = HTTParty.post(url, headers: api_headers, body: body.to_json, timeout: 10)
    log_provider_failure(action_name, response) unless response.success?
    response.success?
  end

  def permission_request_body(to_phone_number, body_text)
    {
      messaging_product: 'whatsapp', recipient_type: 'individual', to: to_phone_number,
      type: 'interactive',
      interactive: {
        type: 'call_permission_request',
        action: { name: 'call_permission_request' },
        body: { text: body_text }
      }
    }.to_json
  end

  def initiate_call_body(to_phone_number, sdp_offer)
    {
      messaging_product: 'whatsapp', to: to_phone_number, action: 'connect',
      session: { sdp: sdp_offer, sdp_type: 'offer' }
    }.to_json
  end

  def process_initiate_call_response(response)
    return response.parsed_response if response.success?

    log_provider_failure('initiate', response)
    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response : {}
    error = parsed['error'].is_a?(Hash) ? parsed['error'] : {}
    error_code = error['code']
    raise Voice::CallErrors::NoCallPermission, 'WhatsApp call permission is required' if
      error_code == Voice::CallErrors::NO_CALL_PERMISSION_CODE

    raise Voice::CallErrors::CallFailed, 'WhatsApp call provider request failed'
  end

  def log_provider_failure(action, response)
    parsed = response.parsed_response.is_a?(Hash) ? response.parsed_response : {}
    code = parsed.dig('error', 'code').to_s.gsub(/[^0-9A-Za-z_-]/, '').first(40).presence || 'none'
    Rails.logger.error(
      "LLA_WHATSAPP_PROVIDER_FAILED account=#{whatsapp_channel.account_id} channel=#{whatsapp_channel.id} " \
      "action=#{action} status=#{response.code} code=#{code}"
    )
  end
end
