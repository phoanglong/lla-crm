# frozen_string_literal: true

class Lla::Voice::WhatsappEventClaim
  CLAIM_TTL = 2.minutes
  MAX_PAYLOAD_BYTES = 1.megabyte

  def initialize(request:, channel:)
    @request = request
    @channel = channel
  end

  def claim!
    raise ActionController::BadRequest, 'WhatsApp voice payload is too large' if request.raw_post.bytesize > MAX_PAYLOAD_BYTES

    event = Lla::Voice::CallEvent.create!(event_attributes)
    [event, false]
  rescue ActiveRecord::RecordNotUnique
    claim_existing!
  end

  private

  attr_reader :request, :channel

  def claim_existing!
    event = event_scope.find_by!(event_id_digest: event_id_digest)
    duplicate = false
    event.with_lock do
      duplicate = event.outcome == 'applied' || active_claim?(event)
      event.update!(outcome: 'pending', payload_digest: payload_digest, verified_at: Time.current) unless duplicate
    end
    [event, duplicate]
  end

  def active_claim?(event)
    event.outcome == 'pending' && event.verified_at > CLAIM_TTL.ago
  end

  def event_scope
    Lla::Voice::CallEvent.where(account_id: channel.account_id, inbox_id: channel.inbox.id, provider: :whatsapp)
  end

  def event_attributes
    {
      account: channel.account,
      inbox: channel.inbox,
      provider: :whatsapp,
      event_id_digest: event_id_digest,
      payload_digest: payload_digest,
      event_type: event_type,
      outcome: 'pending',
      occurred_at: nil,
      verified_at: Time.current
    }
  end

  def event_id_digest
    @event_id_digest ||= Digest::SHA256.hexdigest([signature, payload_digest].join(':'))
  end

  def payload_digest
    @payload_digest ||= Digest::SHA256.hexdigest(request.raw_post)
  end

  def signature
    request.headers['X-Hub-Signature-256'].to_s
  end

  def event_type
    field = request.request_parameters.dig('entry', 0, 'changes', 0, 'field').to_s
    field == 'calls' ? 'whatsapp.calls' : 'whatsapp.call_permission_reply'
  end
end
