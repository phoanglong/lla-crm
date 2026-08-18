# frozen_string_literal: true

# Single canonical entry point for "which portal, if any, does this Host header
# belong to?". Public, dashboard and locale lookup all go through here so an
# unusual Host cannot be normalised three different ways.
#
# Only an `active` lifecycle row on a non-archived portal resolves; a hostname that
# is merely requested, pending, failed or being removed does not serve content.
class Lla::CustomDomains::HostResolver
  def self.portal_for(host)
    canonical = Lla::CustomDomains::HostCanonicalizer.canonicalize(host)
    return if canonical.blank? || installation_host?(canonical)

    domain = Lla::CustomDomains::Domain.active.find_by(hostname: canonical)
    return if domain.blank?

    portal = domain.portal
    return if portal.blank? || portal.archived? || portal.account_id != domain.account_id

    portal
  end

  # The installation's own hostnames are never custom domains.
  def self.installation_host?(host)
    installation_hosts.include?(host)
  end

  def self.installation_hosts
    %w[FRONTEND_URL HELPCENTER_URL].filter_map do |key|
      value = ENV.fetch(key, nil)
      next if value.blank?

      Lla::CustomDomains::HostCanonicalizer.canonicalize(URI.parse(value).host)
    rescue URI::InvalidURIError
      nil
    end
  end
  private_class_method :installation_hosts
end
