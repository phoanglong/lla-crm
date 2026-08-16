class Twilio::VoiceController < ApplicationController
  CONFERENCE_EVENT_PATTERNS = {
    /conference-start/i => 'start',
    /participant-join/i => 'join',
    /participant-leave/i => 'leave',
    /conference-end/i => 'end'
  }.freeze

  before_action :load_channel_for_signature
  before_action :verify_twilio_request!
  before_action :set_inbox!
  around_action :track_twilio_event

  rescue_from Lla::Voice::TwilioRequestVerifier::VerificationError, with: :render_invalid_twilio_request

  def status
    @call = Voice::StatusUpdateService.new(
      account: current_account,
      inbox: inbox,
      call_sid: twilio_call_sid,
      call_status: params[:CallStatus],
      payload: params.to_unsafe_h
    ).perform

    head :no_content
  end

  def call_twiml
    return render xml: reject_twiml if reject_inbound?

    @call = resolve_call
    render xml: Lla::Voice::TwilioTwimlBuilder.new(
      call: @call,
      channel: inbox_channel,
      agent_leg: agent_leg?(twilio_from),
      participant_label: participant_label_for(twilio_from)
    ).to_xml
  end

  def conference_status
    event = mapped_conference_event
    if event.nil?
      Rails.logger.info("LLA_TWILIO_EVENT_IGNORED account=#{current_account.id} inbox=#{inbox.id} type=conference")
      return head :no_content
    end

    @call = find_call_for_conference!(params[:FriendlyName], twilio_call_sid)
    persist_twilio_conference_sid!(@call, params[:ConferenceSid])

    Voice::Conference::Manager.new(
      call: @call,
      event: event,
      participant_label: participant_label
    ).process

    head :no_content
  end

  def recording_status
    @call = Voice::RecordingStatusService.new(
      account: current_account,
      inbox: inbox,
      payload: params.to_unsafe_h
    ).perform

    head :no_content
  end

  private

  def verify_twilio_request!
    @twilio_event = Lla::Voice::TwilioRequestVerifier.new(
      request: request,
      channel: @twilio_channel,
      action_name: action_name
    ).verify!
  end

  def track_twilio_event
    yield
    update_twilio_event!('applied')
  rescue StandardError
    update_twilio_event!('rejected')
    raise
  end

  def update_twilio_event!(outcome)
    return if @twilio_event.blank?

    call = @call if @call && inbox && @call.account_id == inbox_account.id && @call.inbox_id == inbox.id
    @twilio_event.update!(outcome: outcome, call: call)
  end

  def render_invalid_twilio_request
    update_twilio_event!('rejected') if @twilio_event
    head :forbidden
  end

  def twilio_call_sid
    params[:CallSid]
  end

  def twilio_from
    params[:From].to_s
  end

  def twilio_to
    params[:To]
  end

  def twilio_direction
    @twilio_direction ||= (params['Direction'] || params['CallDirection']).to_s
  end

  def mapped_conference_event
    event = params[:StatusCallbackEvent].to_s
    CONFERENCE_EVENT_PATTERNS.each do |pattern, mapped|
      return mapped if event.match?(pattern)
    end
    nil
  end

  def agent_leg?(from_number)
    from_number.start_with?('client:')
  end

  # A fresh contact-initiated leg on an inbox with inbound calls turned off.
  # Reject it so no conference, conversation, or Call row is created.
  def reject_inbound?
    twilio_direction == 'inbound' && !agent_leg?(twilio_from) && !inbox.channel.inbound_calls_enabled?
  end

  def reject_twiml
    Twilio::TwiML::VoiceResponse.new(&:reject).to_s
  end

  def resolve_call
    return find_call_for_agent if agent_leg?(twilio_from)

    case twilio_direction
    when 'inbound'
      Voice::InboundCallBuilder.perform!(
        inbox: inbox,
        call_sid: twilio_call_sid,
        caller: { source_ids: [twilio_from], contact_attributes: { name: twilio_from, phone_number: twilio_from } }
      )
    when 'outbound-api', 'outbound-dial'
      sync_outbound_leg(call_sid: twilio_call_sid, direction: twilio_direction)
    else
      raise ArgumentError, "Unsupported Twilio direction: #{twilio_direction}"
    end
  end

  def find_call_for_agent
    sid = params[:call_sid].presence
    raise ArgumentError, 'call_sid is required for agent leg' if sid.blank?

    inbox_calls.find_by!(provider_call_id: sid)
  end

  def sync_outbound_leg(call_sid:, direction:)
    parent_sid = params['ParentCallSid'].presence
    lookup_sid = direction == 'outbound-dial' ? parent_sid || call_sid : call_sid
    call = inbox_calls.find_by!(provider_call_id: lookup_sid)

    call.update!(parent_call_sid: parent_sid) if parent_sid.present? && call.parent_call_sid != parent_sid
    call
  end

  def inbox_calls
    Call.where(inbox_id: inbox.id, provider: :twilio)
  end

  def participant_label_for(from_number)
    return from_number.delete_prefix('client:') if from_number.start_with?('client:')

    'contact'
  end

  def find_call_for_conference!(friendly_name, call_sid)
    name = friendly_name.to_s
    call = inbox_calls.by_conference_sid(name).first if name.present?
    call || inbox_calls.find_by!(provider_call_id: call_sid)
  end

  # Twilio's recording webhook only sends its internal ConferenceSid (CF...),
  # not our FriendlyName. Persist Twilio's id the first time we see it on a
  # conference event so the recording lookup can match later.
  def persist_twilio_conference_sid!(call, sid)
    return if sid.blank?
    return if call.twilio_conference_sid == sid

    call.update!(twilio_conference_sid: sid)
  end

  def load_channel_for_signature
    digits = params[:phone].to_s
    @twilio_channel = Channel::TwilioSms.find_by(phone_number: "+#{digits}") if digits.match?(/\A\d{7,15}\z/)
  end

  def set_inbox!
    raise Lla::Voice::TwilioRequestVerifier::VerificationError, 'voice channel unavailable' unless voice_channel_enabled?

    @inbox = @twilio_channel.inbox
  end

  def voice_channel_enabled?
    @twilio_channel&.voice_enabled? && @twilio_channel.account.feature_enabled?('channel_voice')
  end

  def current_account
    @current_account ||= inbox_account
  end

  def participant_label
    params[:ParticipantLabel].to_s
  end

  attr_reader :inbox

  delegate :account, :channel, to: :inbox, prefix: true
end
