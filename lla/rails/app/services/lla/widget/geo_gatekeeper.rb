# frozen_string_literal: true

# Optional, default-OFF widget GeoIP allowlist enforcement owned by LLA (ADR-OMCRM-032).
#
# Gates (all must be true to enforce): global env flag, account capability
# (`ip_lookup`), account policy `enabled`, and provider `consent_enabled`. If any gate
# is off, or the allowlist is not configured, the decision is a bypass with zero
# provider egress. Provider output is validated against the ISO registry; malformed or
# missing output becomes a typed unavailable decision (strict = fail-closed, open =
# fail-open). Decisions are cached per tenant/widget using a hashed IP key (never the
# raw IP) which also bounds the provider call rate within the TTL.
class Lla::Widget::GeoGatekeeper
  CACHE_TTL = 5.minutes
  UNAVAILABLE_CACHE_TTL = 1.minute
  UNAVAILABLE_SENTINEL = '__geo_unavailable__'
  CACHE_NAMESPACE = 'lla:widget_geo'
  OPEN_MODE = 'open'
  UNAVAILABLE_CODE = 'geoip_lookup_unavailable'
  NOT_ALLOWED_CODE = 'country_not_allowed'
  LOOKUP_ERRORS = [Timeout::Error, SocketError, Errno::ETIMEDOUT, Errno::ECONNREFUSED, Errno::EHOSTUNREACH].freeze

  Decision = Struct.new(:outcome, :country, :reason, keyword_init: true)

  def initialize(web_widget:, client_ip:, global_enabled:, ip_lookup: IpLookupService.new, cache: Rails.cache)
    @web_widget = web_widget
    @account = web_widget.inbox.account
    @client_ip = client_ip.to_s
    @global_enabled = global_enabled
    @ip_lookup = ip_lookup
    @cache = cache
  end

  # Raises Lla::Widget::GeoConfigurationError for invalid configuration.
  def call
    return bypass('not_configured') unless allowlist_configured?
    return bypass('geoip_disabled') unless enforcement_enabled?

    allowlist = Lla::Widget::CountryAllowlist.parse(raw_allowlist)
    country = resolved_country
    return unavailable if country.nil?

    allowlist.include?(country) ? allow(country) : deny(country)
  end

  private

  attr_reader :web_widget, :account, :client_ip, :ip_lookup, :cache

  def allowlist_configured?
    account.custom_attributes.key?('allowed_countries') && !raw_allowlist.nil?
  end

  def raw_allowlist
    account.custom_attributes['allowed_countries']
  end

  def enforcement_enabled?
    @global_enabled &&
      policy_config['enabled'] == true &&
      policy_config['consent_enabled'] == true &&
      account.feature_enabled?('ip_lookup')
  end

  # Concurrent misses for the same tenant/widget/IP coalesce onto one provider call
  # via SingleFlight. A cached nil result is stored as a sentinel so repeated
  # nil/malformed/error lookups stay rate-bounded within the (shorter) unavailable TTL.
  def resolved_country
    stored = single_flight.call(expires_in: method(:cache_ttl_for)) do
      provider_country || UNAVAILABLE_SENTINEL
    end
    cached_country(stored)
  end

  def single_flight
    Lla::Widget::SingleFlight.new(cache: cache, value_key: cache_key, lock_key: lock_key)
  end

  def cache_ttl_for(value)
    value == UNAVAILABLE_SENTINEL ? UNAVAILABLE_CACHE_TTL : CACHE_TTL
  end

  def cached_country(cached)
    cached == UNAVAILABLE_SENTINEL ? nil : cached
  end

  # Maps expected adapter lookup failures to an unavailable result; programming
  # errors are intentionally not rescued so they surface during development.
  def provider_country
    Lla::Widget::IsoCountryRegistry.canonical(provider_country_code)
  rescue *LOOKUP_ERRORS
    nil
  end

  def provider_country_code
    ip_lookup.perform(client_ip)&.country_code
  end

  def cache_key
    "#{CACHE_NAMESPACE}:#{account.id}:#{web_widget.id}:#{ip_digest}"
  end

  def lock_key
    "#{cache_key}:lock"
  end

  def ip_digest
    Digest::SHA256.hexdigest("#{account.id}:#{web_widget.id}:#{client_ip}")
  end

  def policy_config
    config = account.custom_attributes['widget_geoip_policy']
    config.is_a?(Hash) ? config : {}
  end

  def strict?
    policy_config['mode'].to_s != OPEN_MODE
  end

  def unavailable
    strict? ? Decision.new(outcome: :deny, country: nil, reason: UNAVAILABLE_CODE) : allow(nil)
  end

  def allow(country)
    Decision.new(outcome: :allow, country: country, reason: nil)
  end

  def deny(country)
    Decision.new(outcome: :deny, country: country, reason: NOT_ALLOWED_CODE)
  end

  def bypass(reason)
    Decision.new(outcome: :bypass, country: nil, reason: reason)
  end
end
