# frozen_string_literal: true

# Widget country/GeoIP allowlist enforcement owned by LLA (ADR-OMCRM-032).
# Prepended to the MIT WidgetsController via prepend_mod_with.
#
# GeoIP is an optional adapter: global env + capability + account policy + provider
# consent gated, default OFF. When disabled there is zero provider egress. Failure
# mode is an explicit per-account contract (strict = fail-closed, open = fail-open);
# the default is the safe strict path and production mode selection stays UNVERIFIED.
module Lla::WidgetsController
  MAX_ALLOWED_COUNTRIES = 250
  GEO_POLICY_STRICT = 'strict'
  GEO_POLICY_OPEN = 'open'
  GEO_POLICY_ERROR_CODE = 'geoip_policy_invalid'
  GEO_LOOKUP_UNAVAILABLE_CODE = 'geoip_lookup_unavailable'

  class GeoPolicyConfigurationError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super
    end
  end

  private

  def ensure_location_is_supported
    countries = normalized_allowed_countries
    return if countries.nil?
    return audit_geo_policy_decision(result: 'bypass', error_code: 'geoip_disabled') unless geoip_lookup_enabled?

    enforce_country_allowlist(countries)
  rescue GeoPolicyConfigurationError => e
    render_geo_configuration_error(e)
  rescue StandardError
    render_geo_lookup_unavailable
  end

  def enforce_country_allowlist(countries)
    country = resolved_country_code
    return render_geo_lookup_unavailable if country.nil?

    allowed = countries.include?(country)
    audit_geo_policy_decision(result: allowed ? 'allow' : 'deny', country: country,
                              error_code: allowed ? nil : 'country_not_allowed')
    return if allowed

    render json: { error: 'Location is not supported' }, status: :unauthorized
  end

  def resolved_country_code
    result = IpLookupService.new.perform(geo_client_ip)
    result&.country_code.to_s.upcase.presence
  end

  # Only honour X-Forwarded-For when the direct peer is a configured trusted proxy;
  # otherwise use the unspoofable direct connection address so a client cannot forge geo.
  def geo_client_ip
    direct_peer_trusted? ? request.remote_ip : request.remote_addr
  end

  def direct_peer_trusted?
    peer = request.remote_addr
    return false if peer.blank?

    address = IPAddr.new(peer)
    trusted_proxy_ranges.any? { |range| range.respond_to?(:include?) && range.include?(address) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def trusted_proxy_ranges
    ActionDispatch::RemoteIp::TRUSTED_PROXIES + Array(Rails.application.config.action_dispatch.trusted_proxies)
  end

  def render_geo_lookup_unavailable
    return if geo_policy_mode == GEO_POLICY_OPEN

    audit_geo_policy_decision(result: 'deny', error_code: GEO_LOOKUP_UNAVAILABLE_CODE)
    render json: { error: 'Location is not supported', code: GEO_LOOKUP_UNAVAILABLE_CODE }, status: :unauthorized
  end

  def render_geo_configuration_error(error)
    audit_geo_policy_decision(result: 'deny', error_code: error.code)
    render json: { error: 'Invalid country policy configuration', code: error.code }, status: :unprocessable_entity
  end

  def normalized_allowed_countries
    countries = @web_widget.inbox.account.custom_attributes['allowed_countries']
    return if countries.blank?
    raise GeoPolicyConfigurationError, GEO_POLICY_ERROR_CODE unless countries.is_a?(Array)
    raise GeoPolicyConfigurationError, 'country_allowlist_too_large' if countries.size > MAX_ALLOWED_COUNTRIES

    normalized = countries.map { |country| normalize_country_code(country) }
    raise GeoPolicyConfigurationError, 'country_allowlist_duplicate' unless normalized.uniq.size == normalized.size

    normalized
  end

  def normalize_country_code(country)
    code = country.to_s.strip
    raise GeoPolicyConfigurationError, GEO_POLICY_ERROR_CODE unless code.match?(/\A[A-Z]{2}\z/)

    code
  end

  def geoip_lookup_enabled?
    geo_policy_config['enabled'] == true &&
      geo_policy_config['consent_enabled'] == true &&
      @web_widget.inbox.account.feature_enabled?('ip_lookup') &&
      ChatwootApp.env_flag?('LLA_WIDGET_GEOIP_ENABLED')
  end

  def geo_policy_mode
    geo_policy_config['mode'].to_s == GEO_POLICY_OPEN ? GEO_POLICY_OPEN : GEO_POLICY_STRICT
  end

  def geo_policy_config
    @geo_policy_config ||= begin
      config = @web_widget.inbox.account.custom_attributes['widget_geoip_policy']
      config.is_a?(Hash) ? config : {}
    end
  end

  def audit_geo_policy_decision(result:, country: nil, error_code: nil)
    inbox = @web_widget.inbox
    Rails.logger.info(
      {
        event: 'widget_geo_policy_decision',
        account_id: inbox.account_id,
        inbox_id: inbox.id,
        web_widget_id: @web_widget.id,
        country: country,
        result: result,
        error_code: error_code
      }.to_json
    )
  end
end
