# frozen_string_literal: true

# Resolves an Infisical-compatible secret *reference* into a runtime value.
#
# ADR-OMCRM-033: Infisical is the source of truth for system secrets; the
# deployment pipeline injects them as process environment. LLA code therefore
# stores only the reference (path + key), never the secret, and never reads or
# writes plaintext credentials in `InstallationConfig`.
#
#   LLA_CLOUDFLARE_API_TOKEN_REF="infisical://lla/prod/cloudflare#CLOUDFLARE_API_TOKEN"
#   LLA_CLOUDFLARE_API_TOKEN_REF="env://CLOUDFLARE_API_TOKEN"
class Lla::Security::SecretReference
  class InvalidReference < StandardError; end

  REFERENCE_PATTERN = %r{\A(?:infisical://[A-Za-z0-9_.\-/]{1,120}\#|env://)(?<key>[A-Z][A-Z0-9_]{2,60})\z}
  MINIMUM_VALUE_BYTES = 8

  def self.reference?(value)
    REFERENCE_PATTERN.match?(value.to_s)
  end

  def self.key_for(reference)
    match = REFERENCE_PATTERN.match(reference.to_s)
    raise InvalidReference, 'lla_secret_reference_invalid' if match.nil?

    match[:key]
  end

  # Returns nil when the reference is absent or unresolved so every adapter can
  # fail closed instead of guessing a credential.
  def self.resolve(reference)
    return if reference.blank?

    value = ENV.fetch(key_for(reference), nil).to_s
    return if value.bytesize < MINIMUM_VALUE_BYTES

    value
  rescue InvalidReference
    nil
  end

  def self.resolve_from_env(reference_env_name)
    resolve(ENV.fetch(reference_env_name, nil))
  end

  # Reference metadata is safe to log; the value never is.
  def self.describe(reference)
    return 'absent' if reference.blank?
    return 'invalid' unless reference?(reference)

    "ref:#{Digest::SHA256.hexdigest(reference.to_s).first(12)}"
  end
end
