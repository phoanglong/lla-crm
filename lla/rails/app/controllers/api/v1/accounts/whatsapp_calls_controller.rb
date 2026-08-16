class Api::V1::Accounts::WhatsappCallsController < Api::V1::Accounts::BaseController
  before_action :set_call, only: %i[show accept reject terminate upload_recording]
  before_action :set_call_context, only: :initiate
  before_action :ensure_calling_enabled, only: :initiate
  before_action :ensure_sdp_offer, only: :initiate
  before_action :ensure_contact_phone, only: :initiate
  before_action :ensure_recording_present, only: :upload_recording
  before_action :ensure_call_message, only: :upload_recording

  rescue_from Voice::CallErrors::NotRinging,
              Voice::CallErrors::AlreadyAccepted,
              Voice::CallErrors::CallFailed,
              with: :render_call_error
  rescue_from Voice::CallErrors::CallAlreadyEnded, with: :render_call_ended
  rescue_from Voice::CallErrors::NoCallPermission, with: :render_permission_request
  rescue_from Whatsapp::OutboundCallBuilder::InvalidRequest, with: :render_invalid_request
  rescue_from Whatsapp::OutboundCallBuilder::IdempotencyConflict, with: :render_idempotency_conflict
  rescue_from Whatsapp::OutboundCallBuilder::OperationInProgress, with: :render_operation_in_progress
  rescue_from Whatsapp::RecordingAttachmentService::NotAllowed,
              Whatsapp::RecordingAttachmentService::InvalidRecording,
              Lla::Security::MalwareScanner::ThreatDetected,
              with: :render_recording_error
  rescue_from Lla::Security::MalwareScanner::ScannerUnavailable, with: :render_scanner_unavailable

  def show; end

  def accept
    call_service.accept
  end

  def reject
    call_service.reject
  end

  def terminate
    call_service.terminate
  end

  def upload_recording
    @upload_status = Whatsapp::RecordingAttachmentService.new(call: @call, upload: params[:recording]).perform
  end

  def initiate
    @call = outbound_call_builder.perform!
    @conversation = @call.conversation
    @message = @call.message
  end

  private

  def call_service
    @call_service ||= Whatsapp::CallService.new(call: @call, agent: Current.user, sdp_answer: params[:sdp_answer])
  end

  def provider_service
    @provider_service ||= @inbox.channel.provider_service
  end

  def set_call
    @call = Current.account.calls.whatsapp.find(params[:id])
    authorize @call.conversation, :show?
    raise Pundit::NotAuthorizedError unless Current.account.feature_enabled?('channel_voice') &&
                                            @call.inbox.channel.voice_enabled?
  end

  def set_call_context
    params[:conversation_id].present? ? set_context_from_conversation : set_context_from_contact
  end

  def set_context_from_conversation
    @conversation = Current.account.conversations.find_by!(display_id: params[:conversation_id])
    authorize @conversation, :show?
    @inbox = @conversation.inbox
    @contact = @conversation.contact
  end

  def set_context_from_contact
    @inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @inbox, :show?
    @contact = Current.account.contacts.find(params[:contact_id])
    @conversation = conversation_builder.existing_conversation
    # Authorize the thread the call will land in — after the dial is too late to refuse a ringing call.
    authorize(@conversation || conversation_builder.new_conversation, :show?)
  end

  def conversation_builder
    @conversation_builder ||= Whatsapp::CallConversationBuilder.new(inbox: @inbox, contact: @contact, user: Current.user)
  end

  # Created only after the dial succeeds, so a failed call leaves no empty thread and there is nothing to
  # roll back. Re-authorized because a concurrent caller may have created the thread we get back.
  def open_conversation!
    (@conversation || conversation_builder.perform!).tap { |conversation| authorize conversation, :show? }
  end

  def ensure_calling_enabled
    channel = @inbox.channel
    return if Current.account.feature_enabled?('channel_voice') && channel.is_a?(Channel::Whatsapp) && channel.voice_enabled?

    render_could_not_create_error(I18n.t('errors.whatsapp.calls.not_enabled'))
  end

  def ensure_sdp_offer
    Lla::Voice::SdpStore.validate!('offer', params[:sdp_offer])
  rescue ArgumentError
    render_could_not_create_error(I18n.t('errors.whatsapp.calls.sdp_offer_required'))
  end

  def ensure_contact_phone
    return if @contact.phone_number.present?

    render_could_not_create_error(I18n.t('errors.whatsapp.calls.contact_phone_required'))
  end

  def ensure_recording_present
    return if params[:recording].present?

    render_could_not_create_error(I18n.t('errors.whatsapp.calls.no_recording'))
  end

  def ensure_call_message
    return if @call.message.present?

    render_could_not_create_error(I18n.t('errors.whatsapp.calls.no_message'))
  end

  def outbound_call_builder
    Whatsapp::OutboundCallBuilder.new(
      account: Current.account,
      inbox: @inbox,
      user: initiating_user,
      contact: @contact,
      conversation: @conversation,
      conversation_builder: conversation_builder,
      sdp_offer: params[:sdp_offer],
      idempotency_key: request.headers['Idempotency-Key']
    )
  end

  def render_permission_request
    # Raised mid-dial, so a fresh contact has no thread yet — open one for the opt-in template to land in.
    @conversation = open_conversation!
    status = Whatsapp::CallPermissionRequestService.new(conversation: @conversation, user: initiating_user).perform

    return render_could_not_create_error(I18n.t('errors.whatsapp.calls.permission_request_failed')) if status == 'failed'

    # 422 (not 200) so any client treating 2xx as "call placed" can't mistake
    # the permission-template path for a successful dial. The FE composable
    # detects this status and surfaces the banner instead of throwing.
    render json: { status: status, conversation_id: @conversation.display_id }, status: :unprocessable_entity
  end

  def render_call_error(error)
    render_could_not_create_error(error.message)
  end

  # 409 (not 422) so the FE can tell "already ended" from a generic failure and dismiss the ringing UI.
  def render_call_ended
    render json: { error: I18n.t('errors.whatsapp.calls.already_ended') }, status: :conflict
  end

  def render_idempotency_conflict(error)
    render json: { error: error.message }, status: :conflict
  end

  def render_invalid_request(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def render_operation_in_progress(error)
    render json: { error: error.message }, status: :accepted
  end

  def render_recording_error(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def render_scanner_unavailable
    render json: { error: 'Recording security scanner is unavailable' }, status: :service_unavailable
  end

  def initiating_user
    @initiating_user ||= Current.user
  end
end
