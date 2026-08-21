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
#
# Concurrent misses for one key coalesce through `Lla::Widget::SingleFlight`, so a
# burst of cold requests makes one provider call, not one per request. A waiter that
# exhausts its budget gets `unavailable` — it never makes its own call, which is what
# keeps the bound hard when the provider is slow.
class Lla::Widget::GeoGatekeeper
  CACHE_TTL = 5.minutes
  UNAVAILABLE_CACHE_TTL = 1.minute
  UNAVAILABLE_SENTINEL = '__geo_unavailable__'
  CACHE_NAMESPACE = 'lla:widget_geo'
  OPEN_MODE = 'open'
  UNAVAILABLE_CODE = 'geoip_lookup_unavailable'
  NOT_ALLOWED_CODE = 'country_not_allowed'

  # Failures of the outside world. Expected, bounded, and mapped to `unavailable`.
  LOOKUP_ERRORS = [Timeout::Error, SocketError, Errno::ETIMEDOUT, Errno::ECONNREFUSED,
                   Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET,
                   IPAddr::InvalidAddressError].freeze
  # Defects in this codebase. Never converted into an availability decision — they
  # must surface so they get fixed. Everything else the adapter stack can raise
  # (the MaxMind reader raises a bare RuntimeError on a truncated database, Geocoder
  # raises its own hierarchy) is treated as an outage rather than a 500 on a public
  # unauthenticated endpoint, and is reported with its class name.
  PROGRAMMING_ERRORS = [NoMethodError, NameError, ArgumentError, TypeError,
                        NotImplementedError, FrozenError].freeze

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
    return false unless account.custom_attributes.key?('allowed_countries')

    !Lla::Widget::CountryAllowlist.unset?(raw_allowlist)
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
  # via SingleFlight. A nil result is stored as a sentinel so repeated
  # nil/malformed/error lookups stay rate-bounded within the (shorter) unavailable
  # TTL. A waiter that exhausts its budget reports unavailable instead of making a
  # duplicate call.
  def resolved_country
    stored = single_flight.call(expires_in: method(:cache_ttl_for)) do
      provider_country || UNAVAILABLE_SENTINEL
    end
    cached_country(stored)
  rescue Lla::Widget::SingleFlight::WaitTimeout
    report_lookup_outage('single_flight_wait_timeout', expected: true)
    nil
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

  # The provider is never handed a value that is not an IP address: the adapter
  # stack turns that into an exception deep inside a third-party gem, on an
  # unauthenticated endpoint.
  def provider_country
    return nil if parsed_client_ip.nil?

    Lla::Widget::IsoCountryRegistry.canonical(provider_country_code)
  rescue *PROGRAMMING_ERRORS
    raise
  rescue StandardError => e
    report_lookup_outage(e.class.name, expected: LOOKUP_ERRORS.any? { |kind| e.is_a?(kind) })
    nil
  end

  # `IpLookupService` rescues `Errno::ETIMEDOUT` and returns the value of
  # `Rails.logger.warn`, which is `true`. Anything that does not answer
  # `country_code` is treated as no result rather than being sent `country_code`.
  def provider_country_code
    result = ip_lookup.perform(client_ip)
    return nil unless result.respond_to?(:country_code)

    result.country_code
  end

  def parsed_client_ip
    @parsed_client_ip ||= IPAddr.new(client_ip)
  rescue IPAddr::InvalidAddressError
    nil
  end

  # `expected: false` is an outage shape this code did not anticipate — a truncated
  # MaxMind database raises a bare RuntimeError, for instance. It is still not worth
  # a 500 on an unauthenticated public endpoint, but it is worth telling apart from
  # an ordinary timeout when someone reads the logs.
  def report_lookup_outage(error_class, expected: true)
    Rails.logger.info({ event: 'widget_geo_lookup_unavailable', account_id: account.id,
                        web_widget_id: web_widget.id, error: error_class, expected: expected }.to_json)
  end

  def cache_key
    "#{CACHE_NAMESPACE}:#{account.id}:#{web_widget.id}:#{ip_digest}"
  end

  def lock_key
    "#{cache_key}:lock"
  end

  # Keyed, not plain: `account.id` and `web_widget.id` are enumerable and IPv4 is a
  # 2^32 space, so an unsalted digest in a shared Redis is a reversible record of
  # which IP visited which widget.
  def ip_digest
    OpenSSL::HMAC.hexdigest('SHA256', hmac_key, "#{account.id}:#{web_widget.id}:#{client_ip}")
  end

  def hmac_key
    Rails.application.secret_key_base.to_s
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
