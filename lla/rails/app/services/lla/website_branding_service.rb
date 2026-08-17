# frozen_string_literal: true

# Account-aware gate for the whole onboarding brand lookup. Both egress paths are
# gated: the optional Context.dev provider (`context_dev` consent) and the built-in
# HTML scrape plus MX probe of the customer's domain (`direct_fetch` consent).
# With a gate closed this service performs zero network activity — it neither calls
# the provider nor falls through to `super`, and it never resolves DNS. No provider
# body, email or API key is ever logged.
module Lla::WebsiteBrandingService
  ENDPOINT = 'https://api.context.dev/v1/brand/retrieve-by-email'
  TIMEOUT = 6
  API_KEY_REFERENCE_ENV = 'LLA_CONTEXT_DEV_API_KEY_REF'
  MAX_TEXT_LENGTH = Lla::Branding::ContextPayload::MAX_TEXT_LENGTH

  def initialize(email, account: nil)
    @lla_account = account
    super(email)
  end

  def perform
    brand = lla_enrichment_permitted? ? lla_fetch_brand : nil
    return brand if brand.present?
    return unless lla_local_fetch_permitted?

    super
  end

  private

  attr_reader :lla_account

  # The base MX probe is outbound traffic, so it needs the same explicit consent.
  def detect_email_provider
    return unless lla_local_fetch_permitted?

    super
  end

  def lla_enrichment_permitted?
    lla_account.present? &&
      lla_api_key.present? &&
      Lla::Knowledge::ProviderPolicy.egress_permitted?(
        account: lla_account, provider: :context_dev, capability: :website_enrichment
      )
  end

  def lla_local_fetch_permitted?
    lla_account.present? &&
      Lla::Knowledge::ProviderPolicy.egress_permitted?(
        account: lla_account, provider: :direct_fetch, capability: :website_enrichment
      )
  end

  def lla_api_key
    Lla::Security::SecretReference.resolve_from_env(API_KEY_REFERENCE_ENV)
  end

  def lla_fetch_brand
    response = HTTParty.get(
      ENDPOINT, query: { email: @email },
                headers: { 'Authorization' => "Bearer #{lla_api_key}", 'Accept' => 'application/json' },
                timeout: TIMEOUT, follow_redirects: false
    )
    return lla_log_failure(response.code) unless response.success?

    payload = response.parsed_response
    return unless payload.is_a?(Hash)

    Lla::Branding::ContextPayload.normalize(
      payload['brand'], domain: @domain, email: @email, email_provider: detect_email_provider
    )
  rescue StandardError => e
    Rails.logger.warn("[LlaWebsiteBranding] context_dev_failed error=#{e.class.name}")
    nil
  end

  def lla_log_failure(status)
    Rails.logger.warn("[LlaWebsiteBranding] context_dev_status=#{status.to_i}")
    nil
  end
end
