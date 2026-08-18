# frozen_string_literal: true

class Lla::CustomDomains::ProviderRegistry
  ADAPTERS = {
    'none' => Lla::CustomDomains::Providers::NullProvider,
    'cloudflare' => Lla::CustomDomains::Providers::CloudflareProvider
  }.freeze

  def self.for(provider)
    ADAPTERS.fetch(provider.to_s, Lla::CustomDomains::Providers::NullProvider)
  end

  # The provider a *new* domain request should use. Cloudflare is opt-in and is
  # only selected when every gate for that specific account is already open —
  # global egress, capability, account consent and both secret references. A
  # half-configured install keeps working on the local adapter instead of
  # selecting a provider it is not allowed to call.
  def self.default_provider(account:)
    return 'cloudflare' if Lla::CustomDomains::Providers::CloudflareProvider.available_for?(account)

    'none'
  end
end
