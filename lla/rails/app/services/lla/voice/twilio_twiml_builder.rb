# frozen_string_literal: true

class Lla::Voice::TwilioTwimlBuilder
  def initialize(call:, channel:, agent_leg:, participant_label:)
    @call = call
    @channel = channel
    @agent_leg = agent_leg
    @participant_label = participant_label
  end

  def to_xml
    Twilio::TwiML::VoiceResponse.new.tap do |response|
      response.dial do |dial|
        dial.conference(conference_sid, **conference_options)
      end
    end.to_s
  end

  private

  attr_reader :call, :channel, :agent_leg, :participant_label

  def conference_sid
    call.conference_sid.presence || call.default_conference_sid.tap { |sid| call.update!(conference_sid: sid) }
  end

  def conference_options
    options = {
      start_conference_on_enter: agent_leg,
      end_conference_on_exit: false,
      record: recording_enabled? ? 'record-from-start' : 'do-not-record',
      status_callback: callback_url(:twilio_voice_conference_status_url),
      status_callback_event: 'start end join leave',
      status_callback_method: 'POST',
      participant_label: participant_label
    }
    return options unless recording_enabled?

    options.merge(
      recording_status_callback: callback_url(:twilio_voice_recording_status_url),
      recording_status_callback_event: 'completed',
      recording_status_callback_method: 'POST'
    )
  end

  def recording_enabled?
    enabled = ActiveModel::Type::Boolean.new.cast(channel.provider_config['voice_recording_enabled'])
    enabled && call.meta['recording_consent_id'].present?
  end

  def callback_url(route_name)
    Rails.application.routes.url_helpers.public_send(route_name, phone: channel.phone_number.delete_prefix('+'))
  end
end
