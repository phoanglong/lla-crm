# frozen_string_literal: true

# Short-lived authenticated encryption for outbox payloads that may contain
# external URLs or generation hints. The database stores no readable provider
# payload and the token becomes unusable after the maximum dispatch window.
class Lla::Knowledge::PayloadCipher
  PURPOSE = 'lla-knowledge-generation-outbox'
  RETENTION = 48.hours

  def self.encrypt(payload)
    encryptor.encrypt_and_sign(canonical_json(payload), purpose: PURPOSE, expires_in: RETENTION)
  end

  def self.decrypt(token)
    JSON.parse(encryptor.decrypt_and_verify(token, purpose: PURPOSE), symbolize_names: true)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
    raise ArgumentError, 'Invalid or expired knowledge outbox payload'
  end

  def self.digest(payload)
    Digest::SHA256.hexdigest(canonical_json(payload))
  end

  def self.canonical_json(value)
    canonicalize(value).to_json
  end

  def self.encryptor
    @encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key(PURPOSE, 32),
      cipher: 'aes-256-gcm'
    )
  end
  private_class_method :encryptor

  def self.canonicalize(value)
    case value
    when Hash
      value.keys.sort_by(&:to_s).index_with { |key| canonicalize(value[key]) }
    when Array
      value.map { |item| canonicalize(item) }
    else
      value
    end
  end
  private_class_method :canonicalize
end
