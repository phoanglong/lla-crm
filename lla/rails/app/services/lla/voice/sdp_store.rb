# frozen_string_literal: true

class Lla::Voice::SdpStore
  TTL = 5.minutes
  MAX_BYTES = 128.kilobytes
  KINDS = %w[offer answer].freeze

  def self.write(call:, kind:, sdp:)
    validate!(kind, sdp)
    Redis::Alfred.setex(key(call, kind), Lla::Voice::PayloadCipher.encrypt('sdp' => sdp), TTL)
    Digest::SHA256.hexdigest(sdp)
  end

  def self.read(call:, kind:)
    validate_kind!(kind)
    token = Redis::Alfred.get(key(call, kind))
    return if token.blank?

    Lla::Voice::PayloadCipher.decrypt(token)[:sdp]
  end

  def self.delete(call:, kind: nil)
    kinds = kind ? [kind] : KINDS
    kinds.each { |value| Redis::Alfred.delete(key(call, value)) }
  end

  def self.validate!(kind, sdp)
    validate_kind!(kind)
    raise ArgumentError, 'SDP is required' if sdp.blank?
    raise ArgumentError, 'SDP is too large' if sdp.bytesize > MAX_BYTES
    raise ArgumentError, 'Invalid SDP' unless sdp.to_s.start_with?('v=')
  end

  def self.validate_kind!(kind)
    raise ArgumentError, 'Invalid SDP kind' unless KINDS.include?(kind.to_s)
  end

  def self.key(call, kind)
    "LLA_VOICE_SDP::#{call.account_id}:#{call.id}:#{kind}"
  end

  private_class_method :key, :validate_kind!
end
