# frozen_string_literal: true

class Lla::CustomDomains::ChallengeResolver
  def self.resolve(host:, challenge_id:, now: Time.current)
    normalized_host = normalize_host(host)
    return if normalized_host.blank? || challenge_id.blank?

    portal = Portal.active.find_by(custom_domain: normalized_host)
    resolve_portal_challenge(portal, challenge_id.to_s, now)
  rescue ArgumentError
    nil
  end

  def self.resolve_portal_challenge(portal, challenge_id, now)
    return if portal.blank?

    settings = portal.ssl_settings || {}
    expected_id = settings['cf_verification_id'].to_s
    body = settings['cf_verification_body'].to_s
    expiry = Time.zone.parse(settings['cf_verification_expires_at'].to_s)
    return unless usable_challenge?(expected_id, body, expiry, now)
    return unless secure_match?(expected_id, challenge_id)

    body
  end
  private_class_method :resolve_portal_challenge

  def self.usable_challenge?(expected_id, body, expiry, now)
    expected_id.present? && body.present? && expiry.present? && expiry > now
  end
  private_class_method :usable_challenge?

  def self.normalize_host(value)
    host = value.to_s.downcase.delete_suffix('.')
    return if host.blank? || host.bytesize > 253
    return unless Lla::Knowledge::UrlPolicy::HOST_PATTERN.match?(host)

    host
  end
  private_class_method :normalize_host

  def self.secure_match?(left, right)
    return false unless left.bytesize == right.bytesize

    ActiveSupport::SecurityUtils.secure_compare(left, right)
  end
  private_class_method :secure_match?
end
