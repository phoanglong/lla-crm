module Enterprise::WidgetsController
  MAX_ALLOWED_COUNTRIES = 250
  GEO_POLICY_STRICT = 'strict'.freeze
  GEO_POLICY_OPEN = 'open'.freeze
  GEO_POLICY_ERROR_CODE = 'geoip_policy_invalid'.freeze
  GEO_LOOKUP_UNAVAILABLE_CODE = 'geoip_lookup_unavailable'.freeze

  private

  def ensure_location_is_supported
    countries = normalized_allowed_countries
    return if countries.nil?

    unless geoip_lookup_enabled?
      audit_geo_policy_decision(result: 'bypass', error_code: 'geoip_disabled')
      return
    end

    geocoder_result = lookup_country
    if geocoder_result.nil?
      return if geo_policy_mode == GEO_POLICY_OPEN

      audit_geo_policy_decision(result: 'deny', error_code: GEO_LOOKUP_UNAVAILABLE_CODE)
      return render json: { error: 'Location is not supported', code: GEO_LOOKUP_UNAVAILABLE_CODE }, status: :unauthorized
    end

    country_code = geocoder_result.country_code.to_s.upcase
    country_enabled = countries.include?(country_code)
    audit_geo_policy_decision(
      result: country_enabled ? 'allow' : 'deny',
      country: country_code,
      error_code: country_enabled ? nil : 'country_not_allowed'
    )

    return if country_enabled

    render json: { error: 'Location is not supported' }, status: :unauthorized
  rescue GeoPolicyConfigurationError => e
    audit_geo_policy_decision(result: 'deny', error_code: e.code)
    render json: { error: 'Invalid country policy configuration', code: e.code }, status: :unprocessable_entity
  rescue StandardError
    return if geo_policy_mode == GEO_POLICY_OPEN

    audit_geo_policy_decision(result: 'deny', error_code: GEO_LOOKUP_UNAVAILABLE_CODE)
    render json: { error: 'Location is not supported', code: GEO_LOOKUP_UNAVAILABLE_CODE }, status: :unauthorized
  end

  def lookup_country
    IpLookupService.new.perform(request.remote_ip)
  end

  def normalized_allowed_countries
    countries = @web_widget.inbox.account.custom_attributes['allowed_countries']
    return nil if countries.blank?

    raise GeoPolicyConfigurationError.new(GEO_POLICY_ERROR_CODE) unless countries.is_a?(Array)
    raise GeoPolicyConfigurationError.new('country_allowlist_too_large') if countries.size > MAX_ALLOWED_COUNTRIES

    normalized = countries.map do |country|
      code = country.to_s.strip
      raise GeoPolicyConfigurationError.new(GEO_POLICY_ERROR_CODE) if code.blank?
      raise GeoPolicyConfigurationError.new(GEO_POLICY_ERROR_CODE) unless code.match?(/\A[A-Z]{2}\z/)

      code
    end

    raise GeoPolicyConfigurationError.new('country_allowlist_duplicate') unless normalized.uniq.size == normalized.size

    normalized
  end

  def geoip_lookup_enabled?
    geo_policy_config['enabled'] == true &&
      geo_policy_config['consent_enabled'] == true &&
      @web_widget.inbox.account.feature_enabled?('ip_lookup') &&
      ActiveModel::Type::Boolean.new.cast(ENV.fetch('LLA_WIDGET_GEOIP_ENABLED', false))
  end

  def geo_policy_mode
    mode = geo_policy_config['mode'].to_s
    return GEO_POLICY_OPEN if mode == GEO_POLICY_OPEN

    GEO_POLICY_STRICT
  end

  def geo_policy_config
    @geo_policy_config ||= begin
      config = @web_widget.inbox.account.custom_attributes['widget_geoip_policy']
      config.is_a?(Hash) ? config : {}
    end
  end

  def audit_geo_policy_decision(result:, country: nil, error_code: nil)
    Rails.logger.info(
      {
        event: 'widget_geo_policy_decision',
        account_id: @web_widget.inbox.account_id,
        inbox_id: @web_widget.inbox_id,
        web_widget_id: @web_widget.id,
        country: country,
        result: result,
        error_code: error_code
      }.to_json
    )
  end

  class GeoPolicyConfigurationError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end
end
