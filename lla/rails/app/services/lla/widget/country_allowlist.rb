# frozen_string_literal: true

# Canonicalizes and validates a configured widget country allowlist against the
# immutable ISO 3166-1 alpha-2 registry. A present-but-empty list, a blank or
# malformed entry, an oversized payload, or duplicates (after canonicalization)
# all raise a typed configuration error so the caller rejects before any egress.
class Lla::Widget::CountryAllowlist
  INVALID = 'geoip_policy_invalid'
  TOO_LARGE = 'country_allowlist_too_large'
  DUPLICATE = 'country_allowlist_duplicate'

  def self.parse(raw)
    raise Lla::Widget::GeoConfigurationError, INVALID unless raw.is_a?(Array)
    raise Lla::Widget::GeoConfigurationError, INVALID if raw.empty?
    raise Lla::Widget::GeoConfigurationError, TOO_LARGE if raw.size > Lla::Widget::IsoCountryRegistry::ALPHA2.size

    codes = raw.map { |value| canonicalize(value) }
    raise Lla::Widget::GeoConfigurationError, DUPLICATE unless codes.uniq.size == codes.size

    new(codes)
  end

  def self.canonicalize(value)
    Lla::Widget::IsoCountryRegistry.canonical(value) || raise(Lla::Widget::GeoConfigurationError, INVALID)
  end

  def initialize(codes)
    @codes = codes.to_set.freeze
  end

  def include?(code)
    @codes.include?(code)
  end
end
