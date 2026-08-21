# frozen_string_literal: true

# Signs the callback URL used by Firecrawl. The token contains no credential and
# expires after a bounded crawl window. Production must provide a dedicated
# secret through Infisical -> runtime ENV; development/test may use secret_key_base.
class Lla::Captain::FirecrawlWebhookToken
  PURPOSE = 'lla-captain-firecrawl-webhook'
  TTL = 6.hours
  MINIMUM_SECRET_BYTES = 32

  class ConfigurationError < StandardError; end

  def self.generate(assistant)
    verifier.generate(
      { assistant_id: assistant.id, account_id: assistant.account_id },
      expires_in: TTL,
      purpose: PURPOSE
    )
  end

  def self.valid?(token, assistant)
    payload = verifier.verified(token.to_s, purpose: PURPOSE)
    return false if payload.blank?

    secure_id_match?(payload['assistant_id'], assistant.id) && secure_id_match?(payload['account_id'], assistant.account_id)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    false
  end

  def self.verifier
    ActiveSupport::MessageVerifier.new(secret, digest: 'SHA256', serializer: JSON)
  end
  private_class_method :verifier

  def self.secret
    configured = ENV.fetch('CAPTAIN_FIRECRAWL_WEBHOOK_SECRET', nil).presence
    return configured if configured&.bytesize.to_i >= MINIMUM_SECRET_BYTES
    raise ConfigurationError, 'CAPTAIN_FIRECRAWL_WEBHOOK_SECRET must be at least 32 bytes' if configured
    return Rails.application.secret_key_base unless Rails.env.production?

    raise ConfigurationError, 'CAPTAIN_FIRECRAWL_WEBHOOK_SECRET is required in production'
  end
  private_class_method :secret

  def self.secure_id_match?(actual, expected)
    ActiveSupport::SecurityUtils.secure_compare(actual.to_s, expected.to_s)
  end
  private_class_method :secure_id_match?
end
