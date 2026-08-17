# frozen_string_literal: true

class Lla::CustomDomains::ProviderRegistry
  ADAPTERS = {
    'none' => Lla::CustomDomains::Providers::NullProvider,
    'cloudflare' => Lla::CustomDomains::Providers::CloudflareProvider
  }.freeze

  def self.for(provider)
    ADAPTERS.fetch(provider.to_s, Lla::CustomDomains::Providers::NullProvider)
  end

  # The provider a *new* domain request should use. Cloudflare is opt-in and only
  # selected when it is fully configured, so a half-configured install keeps
  # working with the local adapter instead of failing every request.
  def self.default_provider
    return 'cloudflare' if Lla::CustomDomains::Providers::CloudflareProvider.configured?

    'none'
  end
end
