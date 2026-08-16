# frozen_string_literal: true

require 'digest'

class Lla::Voice::TwilioRequestVerifier
  class VerificationError < StandardError; end
  class InvalidSignature < VerificationError; end
  class ReplayDetected < VerificationError; end

  CLAIM_TTL = 2.minutes
  ROUTE_NAMES = {
    'call_twiml' => :twilio_voice_call_url,
    'status' => :twilio_voice_status_url,
    'conference_status' => :twilio_voice_conference_status_url,
    'recording_status' => :twilio_voice_recording_status_url
  }.freeze

  def initialize(request:, channel:, action_name:)
    @request = request
    @channel = channel
    @action_name = action_name.to_s
  end

  def verify!
    raise InvalidSignature, 'invalid Twilio request' unless valid_signature?

    create_or_claim_event!
  end

  def public_url
    route_name = ROUTE_NAMES.fetch(action_name)
    Rails.application.routes.url_helpers.public_send(route_name, phone: phone_digits)
  end

  private

  attr_reader :request, :channel, :action_name

  def valid_signature?
    return false if channel.blank? || channel.auth_token.blank? || signature.blank?

    Twilio::Security::RequestValidator.new(channel.auth_token)
                                      .validate(public_url, request_parameters, signature)
  end

  def signature
    @signature ||= request.headers['X-Twilio-Signature'].to_s
  end

  def request_parameters
    @request_parameters ||= request.request_parameters.to_h.deep_stringify_keys
  end

  def create_or_claim_event!
    Lla::Voice::CallEvent.create!(event_attributes)
  rescue ActiveRecord::RecordNotUnique
    claim_existing_event!
  end

  def claim_existing_event!
    event = event_scope.find_by!(event_id_digest: event_id_digest)
    event.with_lock do
      raise ReplayDetected, 'replayed Twilio request' if event.outcome == 'applied' || active_claim?(event)

      event.update!(outcome: 'pending', payload_digest: payload_digest, verified_at: Time.current)
    end
    event
  end

  def active_claim?(event)
    event.outcome == 'pending' && event.verified_at > CLAIM_TTL.ago
  end

  def event_scope
    Lla::Voice::CallEvent.where(
      account_id: channel.account_id,
      inbox_id: channel.inbox.id,
      provider: :twilio
    )
  end

  def event_attributes
    {
      account_id: channel.account_id,
      inbox_id: channel.inbox.id,
      provider: :twilio,
      event_id_digest: event_id_digest,
      payload_digest: payload_digest,
      event_type: "twilio.#{action_name}",
      outcome: 'pending',
      occurred_at: provider_timestamp,
      verified_at: Time.current
    }
  end

  def event_id_digest
    @event_id_digest ||= Digest::SHA256.hexdigest([action_name, public_url, signature].join(':'))
  end

  def payload_digest
    @payload_digest ||= Digest::SHA256.hexdigest(canonical_payload.to_json)
  end

  def canonical_payload
    request_parameters.sort.to_h.transform_values do |value|
      value.is_a?(Array) ? value.map(&:to_s) : value.to_s
    end
  end

  def provider_timestamp
    value = request_parameters['Timestamp']
    Time.zone.parse(value) if value.present?
  rescue ArgumentError
    nil
  end

  def phone_digits
    channel.phone_number.to_s.delete_prefix('+')
  end
end
