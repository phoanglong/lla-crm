# frozen_string_literal: true

# Authenticated encryption for the ownership proof body. The purpose is bound to
# the canonical hostname, so a ciphertext copied onto another tenant's row cannot
# be decrypted, and the message expires with the challenge itself.
class Lla::CustomDomains::ChallengeCipher
  class InvalidChallenge < StandardError; end

  PURPOSE = 'lla-custom-domain-challenge'

  def self.encrypt(body, hostname:, expires_at:)
    encryptor.encrypt_and_sign(body.to_s, purpose: purpose_for(hostname), expires_at: expires_at)
  end

  def self.decrypt(ciphertext, hostname:)
    encryptor.decrypt_and_verify(ciphertext.to_s, purpose: purpose_for(hostname))
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    raise InvalidChallenge, 'lla_custom_domain_challenge_unreadable'
  end

  def self.digest(challenge_id, hostname:)
    Digest::SHA256.hexdigest("#{purpose_for(hostname)}\0#{challenge_id}")
  end

  def self.purpose_for(hostname)
    "#{PURPOSE}:#{hostname}"
  end
  private_class_method :purpose_for

  def self.encryptor
    @encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key(PURPOSE, 32), cipher: 'aes-256-gcm'
    )
  end
  private_class_method :encryptor
end
