# frozen_string_literal: true

# Serves the ownership proof for exactly one live challenge on exactly one
# canonical host. Everything else — unknown host, wrong id, expired, revoked,
# already active, another tenant's challenge — returns nil, which the controller
# renders as an indistinguishable 404.
class Lla::CustomDomains::ChallengeResolver
  def self.resolve(host:, challenge_id:, now: Time.current)
    canonical = Lla::CustomDomains::HostCanonicalizer.canonicalize(host)
    return if canonical.blank? || challenge_id.blank?

    domain = Lla::CustomDomains::Domain.find_by(hostname: canonical)
    return if domain.blank? || domain.state != 'ownership_pending'

    Lla::CustomDomains::OwnershipChallenge.resolve(domain, challenge_id.to_s, now: now)
  end
end
