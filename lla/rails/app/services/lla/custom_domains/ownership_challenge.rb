# frozen_string_literal: true

# Nonce based ownership proof for a custom hostname.
#
# Only a hostname-bound digest of the challenge id is stored in a readable column,
# so the same nonce cannot be replayed against another tenant's domain and the
# stored row cannot be turned back into a servable proof. The id and the proof
# body live together in one authenticated ciphertext that expires with the
# challenge and can be rotated a bounded number of times.
class Lla::CustomDomains::OwnershipChallenge
  class RotationExhausted < StandardError; end

  TTL = 24.hours
  ID_BYTES = 24
  BODY_BYTES = 32
  CHALLENGE_PATH_PREFIX = '/.well-known/cf-custom-hostname-challenge/'

  Issued = Struct.new(:id, :body, :expires_at, keyword_init: true)

  def self.issue!(domain, now: Time.current)
    write(domain, now: now, rotation: false)
  end

  def self.rotate!(domain, now: Time.current)
    raise RotationExhausted if domain.challenge_rotations >= Lla::CustomDomains::Domain::MAX_CHALLENGE_ROTATIONS

    write(domain, now: now, rotation: true)
  end

  def self.revoke!(domain)
    domain.update!(challenge_id_digest: nil, challenge_ciphertext: nil,
                   challenge_expires_at: nil, challenge_rotated_at: nil)
  end

  # Returns the proof body only for the exact, unexpired challenge of the exact
  # canonical host. Every other input is indistinguishable from "no challenge".
  def self.resolve(domain, challenge_id, now: Time.current)
    return if domain.blank? || challenge_id.blank?
    return unless domain.challenge_active?(now)

    presented = Lla::CustomDomains::ChallengeCipher.digest(challenge_id.to_s, hostname: domain.hostname)
    return unless secure_match?(domain.challenge_id_digest.to_s, presented)

    payload(domain)&.fetch(:body, nil)
  end

  # Path the customer's DNS has to serve for the proof to succeed. Nil once the
  # challenge is expired or revoked, so no stale URL is ever probed.
  def self.probe_path(domain, now: Time.current)
    return unless domain.challenge_active?(now)

    id = payload(domain)&.fetch(:id, nil)
    return if id.blank?

    "#{CHALLENGE_PATH_PREFIX}#{id}"
  end

  def self.matches?(domain, presented_body, now: Time.current)
    return false unless domain.challenge_active?(now)

    expected = payload(domain)&.fetch(:body, nil)
    secure_match?(expected.to_s, presented_body.to_s)
  end

  def self.payload(domain)
    plaintext = Lla::CustomDomains::ChallengeCipher.decrypt(domain.challenge_ciphertext, hostname: domain.hostname)
    JSON.parse(plaintext, symbolize_names: true)
  rescue Lla::CustomDomains::ChallengeCipher::InvalidChallenge, JSON::ParserError
    nil
  end
  private_class_method :payload

  def self.write(domain, now:, rotation:)
    id = SecureRandom.urlsafe_base64(ID_BYTES)
    body = SecureRandom.urlsafe_base64(BODY_BYTES)
    expires_at = now + TTL

    domain.update!(
      challenge_id_digest: Lla::CustomDomains::ChallengeCipher.digest(id, hostname: domain.hostname),
      challenge_ciphertext: Lla::CustomDomains::ChallengeCipher.encrypt(
        { id: id, body: body }.to_json, hostname: domain.hostname, expires_at: expires_at
      ),
      challenge_expires_at: expires_at,
      challenge_rotated_at: (now if rotation),
      challenge_rotations: domain.challenge_rotations + (rotation ? 1 : 0)
    )

    Issued.new(id: id, body: body, expires_at: expires_at)
  end
  private_class_method :write

  def self.secure_match?(left, right)
    return false if left.blank? || right.blank?
    return false unless left.bytesize == right.bytesize

    ActiveSupport::SecurityUtils.secure_compare(left, right)
  end
  private_class_method :secure_match?
end
