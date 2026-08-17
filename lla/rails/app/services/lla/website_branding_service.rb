# frozen_string_literal: true

# Optional Context.dev enrichment for the onboarding brand lookup.
#
# It is default OFF and account scoped: without the capability flag, the global
# egress switch, the account consent and a resolvable secret reference, this
# module performs zero network activity and the local HTML scrape (`super`) is
# used unchanged. No provider body, email or API key is ever logged.
module Lla::WebsiteBrandingService
  ENDPOINT = 'https://api.context.dev/v1/brand/retrieve-by-email'
  TIMEOUT = 6
  API_KEY_REFERENCE_ENV = 'LLA_CONTEXT_DEV_API_KEY_REF'
  MAX_TEXT_LENGTH = 500
  MAX_COLLECTION_SIZE = 20

  def initialize(email, account: nil)
    @lla_account = account
    super(email)
  end

  def perform
    return super unless lla_enrichment_permitted?

    brand = lla_fetch_brand
    return super if brand.blank?

    brand
  end

  private

  attr_reader :lla_account

  def lla_enrichment_permitted?
    lla_account.present? &&
      lla_api_key.present? &&
      Lla::Knowledge::ProviderPolicy.egress_permitted?(
        account: lla_account, provider: :context_dev, capability: :website_enrichment
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

    lla_format_brand(payload['brand'])
  rescue StandardError => e
    Rails.logger.warn("[LlaWebsiteBranding] context_dev_failed error=#{e.class.name}")
    nil
  end

  def lla_log_failure(status)
    Rails.logger.warn("[LlaWebsiteBranding] context_dev_status=#{status.to_i}")
    nil
  end

  # Provider output is untrusted data: strings are bounded, collections are
  # capped and every URL has to survive the shared URL policy before it is stored.
  def lla_format_brand(brand)
    return if brand.blank? || !brand.is_a?(Hash)

    WebsiteBrandingService::DATA_DEFAULTS
      .merge(lla_brand_text(brand))
      .merge(
        domain: @domain, email: @email, email_provider: detect_email_provider,
        colors: lla_colors(brand['colors']), logos: lla_logos(brand['logos']),
        socials: lla_socials(brand['socials']),
        industries: Array(brand.dig('industries', 'eic')).first(MAX_COLLECTION_SIZE).filter_map { |item| lla_text(item) }
      )
  end

  def lla_brand_text(brand)
    %w[title description slogan phone address].index_with { |field| lla_text(brand[field]) }.symbolize_keys
  end

  def lla_text(value)
    return if value.blank? || !value.is_a?(String)

    value.strip.first(MAX_TEXT_LENGTH).presence
  end

  def lla_colors(values)
    Array(values).first(MAX_COLLECTION_SIZE).filter_map do |color|
      hex = color.is_a?(Hash) ? color['hex'] : color
      next unless hex.is_a?(String) && hex.match?(/\A#(?:\h{3}|\h{6})\z/)

      { hex: hex, name: nil }
    end
  end

  def lla_logos(values)
    Array(values).first(MAX_COLLECTION_SIZE).filter_map do |logo|
      url = lla_safe_url(logo.is_a?(Hash) ? logo['url'] : logo)
      next if url.blank?

      { url: url, type: nil, mode: nil, colors: [], resolution: { aspect_ratio: 1 } }
    end
  end

  def lla_socials(values)
    Array(values).first(MAX_COLLECTION_SIZE).filter_map do |social|
      next unless social.is_a?(Hash)

      url = lla_safe_url(social['url'])
      type = lla_text(social['type'])
      next if url.blank? || type.blank?

      { type: type, url: url }
    end
  end

  def lla_safe_url(value)
    Lla::Knowledge::UrlPolicy.canonicalize(value)
  rescue Lla::Knowledge::UrlPolicy::InvalidUrl
    nil
  end
end
