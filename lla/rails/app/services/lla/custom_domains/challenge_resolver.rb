# frozen_string_literal: true

# Serves the ownership proof for exactly one live challenge on exactly one
# canonical host. Everything else — unknown host, wrong id, expired, revoked,
# already active, another tenant's challenge — returns nil, which the controller
# renders as an indistinguishable 404.
class Lla::CustomDomains::ChallengeResolver
  def self.resolve(host:, challenge_id:, now: Time.current)
    canonical = Lla::CustomDomains::HostCanonicalizer.canonicalize(host)
    return if canonical.blank? || challenge_id.blank?
    # The proof is only meaningful when it is served by the *customer's* host. On the
    # installation's own hostnames this application would be answering its own probe.
    return if Lla::CustomDomains::HostResolver.installation_host?(canonical)

    domain = Lla::CustomDomains::Domain.find_by(hostname: canonical)
    return unless servable?(domain)

    Lla::CustomDomains::OwnershipChallenge.resolve(domain, challenge_id.to_s, now: now)
  end

  # Two lifecycle moments legitimately serve a proof: a first claim waiting on
  # ownership, and an active legacy import that an administrator asked to reverify.
  # Everything else (requested, provisioning, active-and-proved, failed, removing)
  # has no live challenge to expose.
  def self.servable?(domain)
    return false if domain.blank?

    domain.state == 'ownership_pending' || (domain.active? && domain.reverify_required?)
  end
end
