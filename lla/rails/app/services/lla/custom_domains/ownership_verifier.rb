# frozen_string_literal: true

# Proves that the customer really controls the hostname by fetching the LLA
# challenge over the public network through the shared SSRF-guarded fetcher.
#
# The result is typed on purpose. `:deferred` means "we were not allowed to look",
# which must never be counted as a failed verification, so a capability that is
# simply switched off cannot burn the operation's retry budget or push a domain
# into `failed`.
class Lla::CustomDomains::OwnershipVerifier
  MAX_BODY_BYTES = 4096
  RESULTS = %i[verified unverified deferred].freeze

  def self.verify(domain, now: Time.current)
    path = Lla::CustomDomains::OwnershipChallenge.probe_path(domain, now: now)
    return :unverified if path.blank?
    return :deferred unless egress_permitted?(domain)

    body = fetch_challenge("https://#{domain.hostname}#{path}")
    Lla::CustomDomains::OwnershipChallenge.matches?(domain, body, now: now) ? :verified : :unverified
  end

  def self.egress_permitted?(domain)
    Lla::Knowledge::ProviderPolicy.egress_permitted?(
      account: domain.account, provider: :direct_fetch, capability: :custom_domains
    )
  end
  private_class_method :egress_permitted?

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
