# frozen_string_literal: true

# Optional Cloudflare custom-hostname adapter. Default OFF: every entry point —
# provision, check *and* teardown — passes the same account-aware gate, so with any
# gate missing no client is constructed and no socket is opened. `provision` only
# ever creates after an authoritative not-found, so an outage cannot duplicate a
# hostname.
class Lla::CustomDomains::Providers::CloudflareProvider
  STATUS_MAX_LENGTH = 64

  def self.name_key
    'cloudflare'
  end

  # Static readiness only (capability flag + resolvable secret references).
  def self.configured?
    Lla::Knowledge::ProviderPolicy.capability_enabled?(:custom_domains) &&
      Lla::CustomDomains::Providers::CloudflareClient.configured?
  end

  # Full, account-aware readiness: this is what any caller must consult before
  # deciding that Cloudflare may be used for a given tenant.
  def self.available_for?(account)
    return false if account.blank?
    return false unless configured?

    Lla::Knowledge::ProviderPolicy.egress_permitted?(
      account: account, provider: :cloudflare, capability: :custom_domains
    )
  end

  def self.provision(domain)
    authorize!(domain.account)

    begin
      existing = find_hostname(domain.hostname)
      return existing if existing.present?

      raise Lla::CustomDomains::ProviderErrors::NotFound
    rescue Lla::CustomDomains::ProviderErrors::NotFound
      create(domain.hostname)
    end
  end

  def self.check(domain)
    authorize!(domain.account)
    find_hostname(domain.hostname) || raise(Lla::CustomDomains::ProviderErrors::NotFound)
  end

  # Teardown is gated exactly like create/verify. When the gate is shut the caller
  # gets a typed `NotConfigured` and defers; the remote resource is not forgotten,
  # it is simply not touched until the tenant is allowed to talk to the provider.
  def self.teardown(hostname, resource_id, account:)
    authorize!(account)
    return true if resource_id.blank?

    begin
      Lla::CustomDomains::Providers::CloudflareClient.delete_custom_hostname(resource_id)
      true
    rescue Lla::CustomDomains::ProviderErrors::NotFound
      # Already gone: teardown is idempotent by contract.
      true
    ensure
      Rails.logger.info("[LlaCustomDomains] cloudflare teardown host_digest=#{host_digest(hostname)}")
    end
  end

  def self.authorize!(account)
    raise Lla::CustomDomains::ProviderErrors::NotConfigured unless available_for?(account)
  end
  private_class_method :authorize!

  def self.find_hostname(hostname)
    result = Lla::CustomDomains::Providers::CloudflareClient.list_custom_hostnames(hostname)
    entry = Array(result).find { |item| item.is_a?(Hash) && item['hostname'].to_s.casecmp?(hostname) }
    return if entry.blank?

    normalize(entry)
  end
  private_class_method :find_hostname

  def self.create(hostname)
    normalize(Lla::CustomDomains::Providers::CloudflareClient.create_custom_hostname(hostname)) ||
      raise(Lla::CustomDomains::ProviderErrors::ServerError)
  end
  private_class_method :create

  # Only an opaque resource ID and a short status string are ever persisted; no
  # verification payload, token or provider error body is carried out of here.
  def self.normalize(entry)
    return if entry.blank?

    resource_id = entry['id'].to_s
    raise Lla::CustomDomains::ProviderErrors::ServerError unless
      Lla::CustomDomains::Providers::CloudflareClient::RESOURCE_ID_PATTERN.match?(resource_id)

    { resource_id: resource_id, status: entry.dig('ssl', 'status').to_s.first(STATUS_MAX_LENGTH).presence || 'unknown' }
  end
  private_class_method :normalize

  def self.host_digest(hostname)
    Digest::SHA256.hexdigest(hostname.to_s).first(12)
  end
  private_class_method :host_digest
end
