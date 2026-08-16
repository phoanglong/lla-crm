# frozen_string_literal: true

class Whatsapp::TerminateTombstoneStore
  TTL = 60

  pattr_initialize [:inbox!]

  def write(payload)
    Redis::Alfred.setex(key(payload[:id]), normalized_payload(payload).to_json, TTL)
  end

  def consume(provider_call_id)
    redis_key = key(provider_call_id)
    raw = Redis::Alfred.get(redis_key)
    return if raw.blank?

    Redis::Alfred.delete(redis_key)
    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  private

  def normalized_payload(payload)
    duration = Integer(payload[:duration], exception: false)
    duration = nil unless duration&.between?(0, 24.hours.to_i)
    reason = payload[:terminate_reason].to_s.gsub(/[^0-9A-Za-z_.:-]/, '').first(80)
    { 'duration' => duration, 'terminate_reason' => reason }
  end

  def key(provider_call_id)
    digest = Digest::SHA256.hexdigest(provider_call_id.to_s)
    "LLA_WHATSAPP_CALL_TERMINATE::#{inbox.account_id}:#{inbox.id}:#{digest}"
  end
end
