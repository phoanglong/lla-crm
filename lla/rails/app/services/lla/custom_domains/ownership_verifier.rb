# frozen_string_literal: true

# Proves that the customer really controls the hostname by fetching the LLA
# challenge over the public network through the shared SSRF-guarded fetcher.
#
# Egress is gated by the same provider policy as every other LLA outbound call, so
# an install without the capability or without account consent performs zero
# network activity and simply reports "unverified".
class Lla::CustomDomains::OwnershipVerifier
  MAX_BODY_BYTES = 4096

  def self.verify(domain, now: Time.current)
    path = Lla::CustomDomains::OwnershipChallenge.probe_path(domain, now: now)
    return false if path.blank?

    Lla::Knowledge::ProviderPolicy.authorize_egress!(
      account: domain.account, provider: :direct_fetch, capability: :custom_domains
    )

    body = fetch_challenge("https://#{domain.hostname}#{path}")
    Lla::CustomDomains::OwnershipChallenge.matches?(domain, body, now: now)
  rescue Lla::Knowledge::ProviderPolicy::Denied
    false
  end

  def self.fetch_challenge(url)
    body = nil
    SafeFetch.fetch(url, validate_content_type: false) { |result| body = result.tempfile.read(MAX_BODY_BYTES) }
    body.to_s.strip
  rescue SafeFetch::Error
    # Never leak the provider/HTTP detail; the operation retry budget decides.
    ''
  end
  private_class_method :fetch_challenge
end
