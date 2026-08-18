# frozen_string_literal: true

# Canonicalizes and validates a configured widget country allowlist against the
# immutable ISO 3166-1 alpha-2 registry.
#
# "Unset" and "invalid" are deliberately different answers. The community
# implementation this replaces did `return if countries.blank?`, so an absent key,
# an empty list and an empty string all meant *no restriction*. Treating an empty
# list as a configuration error instead would take a customer's widget down with a
# 422 the moment an administrator cleared their country restrictions the obvious
# way, so `unset?` keeps the original meaning and only genuinely malformed content
# raises.
#
# A comma- or whitespace-separated String is also accepted: the community code
# called `include?` on whatever was stored, so accounts configured before this
# wave can hold one, and rejecting it would break them at runtime.
class Lla::Widget::CountryAllowlist
  INVALID = 'geoip_policy_invalid'
  TOO_LARGE = 'country_allowlist_too_large'
  DUPLICATE = 'country_allowlist_duplicate'

  # No restriction configured. Not an error: enforcement is simply bypassed.
  # An empty list is *cleared*, not malformed — a list containing a blank entry is
  # malformed and still raises, because that is a typo an administrator wants to see.
  def self.unset?(raw)
    case raw
    when nil then true
    when Array then raw.empty?
    when String then raw.strip.empty?
    else false
    end
  end

  def self.parse(raw)
    entries = entries_for(raw)
    raise Lla::Widget::GeoConfigurationError, INVALID if entries.blank?
    raise Lla::Widget::GeoConfigurationError, TOO_LARGE if entries.size > Lla::Widget::IsoCountryRegistry::ALPHA2.size

    codes = entries.map { |value| canonicalize(value) }
    raise Lla::Widget::GeoConfigurationError, DUPLICATE unless codes.uniq.size == codes.size

    new(codes)
  end

  def self.entries_for(raw)
    case raw
    when Array then raw
    when String then raw.split(/[,\s]+/).reject(&:empty?)
    end
  end
  private_class_method :entries_for

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
