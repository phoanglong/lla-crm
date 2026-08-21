# frozen_string_literal: true

class Lla::Voice::PayloadCipher
  PURPOSE = 'lla-voice-provider-payload'
  RETENTION = 1.hour

  def self.encrypt(payload)
    encryptor.encrypt_and_sign(payload.to_json, purpose: PURPOSE, expires_in: RETENTION)
  end

  def self.decrypt(token)
    JSON.parse(encryptor.decrypt_and_verify(token, purpose: PURPOSE), symbolize_names: true)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
    raise ArgumentError, 'Invalid encrypted voice payload'
  end

  def self.encryptor
    @encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key(PURPOSE, 32),
      cipher: 'aes-256-gcm'
    )
  end

  private_class_method :encryptor
end
