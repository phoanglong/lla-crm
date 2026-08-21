# frozen_string_literal: true

# Normalises an untrusted Context.dev brand payload into the shape the onboarding
# flow expects: strings bounded, collections capped, and every URL forced through
# the shared LLA URL policy before it can be stored or rendered.
class Lla::Branding::ContextPayload
  MAX_TEXT_LENGTH = 500
  MAX_COLLECTION_SIZE = 20
  TEXT_FIELDS = %w[title description slogan phone address].freeze
  HEX_COLOR = /\A#(?:\h{3}|\h{6})\z/

  def self.normalize(brand, domain:, email:, email_provider:)
    return if brand.blank? || !brand.is_a?(Hash)

    WebsiteBrandingService::DATA_DEFAULTS
      .merge(TEXT_FIELDS.index_with { |field| text(brand[field]) }.symbolize_keys)
      .merge(
        domain: domain, email: email, email_provider: email_provider,
        colors: colors(brand['colors']), logos: logos(brand['logos']), socials: socials(brand['socials']),
        industries: Array(brand.dig('industries', 'eic')).first(MAX_COLLECTION_SIZE).filter_map { |item| text(item) }
      )
  end

  def self.text(value)
    return if value.blank? || !value.is_a?(String)

    value.strip.first(MAX_TEXT_LENGTH).presence
  end

  def self.colors(values)
    Array(values).first(MAX_COLLECTION_SIZE).filter_map do |color|
      hex = color.is_a?(Hash) ? color['hex'] : color
      next unless hex.is_a?(String) && HEX_COLOR.match?(hex)

      { hex: hex, name: nil }
    end
  end

  def self.logos(values)
    Array(values).first(MAX_COLLECTION_SIZE).filter_map do |logo|
      url = safe_url(logo.is_a?(Hash) ? logo['url'] : logo)
      next if url.blank?

      { url: url, type: nil, mode: nil, colors: [], resolution: { aspect_ratio: 1 } }
    end
  end

  def self.socials(values)
    Array(values).first(MAX_COLLECTION_SIZE).filter_map do |social|
      next unless social.is_a?(Hash)

      url = safe_url(social['url'])
      type = text(social['type'])
      next if url.blank? || type.blank?

      { type: type, url: url }
    end
  end

  def self.safe_url(value)
    Lla::Knowledge::UrlPolicy.canonicalize(value)
  rescue Lla::Knowledge::UrlPolicy::InvalidUrl
    nil
  end
  private_class_method :safe_url
end
