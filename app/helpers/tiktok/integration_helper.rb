module Tiktok::IntegrationHelper
  # Generates a signed JWT token for Tiktok integration
  #
  # @param account_id [Integer] The account ID to encode in the token
  # @param return_to [String, nil] Optional onboarding return hint
  # @return [String, nil] The encoded JWT token, or nil if it could not be signed
  def generate_tiktok_token(account_id, return_to = nil)
    JWT.encode(token_payload(account_id, return_to), state_signing_key, 'HS256')
  rescue StandardError => e
    Rails.logger.error("Failed to generate TikTok token: #{e.message}")
    nil
  end

  # Verifies and decodes a Tiktok JWT token
  #
  # @param token [String] The JWT token to verify
  # @return [Integer, nil] The account ID from the token or nil if invalid
  def verify_tiktok_token(token)
    return if token.blank?

    decode_token(token, state_signing_key)&.dig('sub')
  end

  # Reads the onboarding return hint from a Tiktok JWT token, if present.
  def tiktok_token_return_to(token)
    return if token.blank?

    decode_token(token, state_signing_key)&.dig('return_to')
  end

  private

  # Ký `state` bằng khoá của máy chủ: mỗi tenant mang ứng dụng riêng là một app secret khác
  # nhau, mà lúc TikTok quay về thì chưa biết tenant nào để chọn khoá giải mã.
  def state_signing_key
    Rails.application.key_generator.generate_key('tiktok oauth state', 32)
  end

  def token_payload(account_id, return_to = nil)
    payload = { sub: account_id, iat: Time.current.to_i }
    payload[:return_to] = return_to if return_to.present?
    payload
  end

  def decode_token(token, secret)
    JWT.decode(token, secret, true, {
                 algorithm: 'HS256',
                 verify_expiration: true
               }).first
  rescue StandardError => e
    Rails.logger.error("Unexpected error verifying Tiktok token: #{e.message}")
    nil
  end
end
