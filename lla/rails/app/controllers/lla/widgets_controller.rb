# frozen_string_literal: true

# Widget country/GeoIP allowlist enforcement owned by LLA (ADR-OMCRM-032).
# Prepended to the MIT WidgetsController via prepend_mod_with.
#
# The decision logic lives in Lla::Widget::GeoGatekeeper; this consumer only resolves a
# trustworthy client IP (never arbitrary X-Forwarded-For), maps the decision to HTTP,
# and audits with internal IDs — never the raw IP or message body.
module Lla::WidgetsController
  private

  def ensure_location_is_supported
    decision = geo_gatekeeper.call
    audit_geo_decision(result: decision.outcome.to_s, country: decision.country, error_code: decision.reason)
    return unless decision.outcome == :deny

    render json: { error: 'Location is not supported', code: decision.reason }.compact, status: :unauthorized
  rescue Lla::Widget::GeoConfigurationError => e
    audit_geo_decision(result: 'deny', error_code: e.code)
    render json: { error: 'Invalid country policy configuration', code: e.code }, status: :unprocessable_entity
  end

  def geo_gatekeeper
    Lla::Widget::GeoGatekeeper.new(
      web_widget: @web_widget,
      client_ip: geo_client_ip,
      global_enabled: ChatwootApp.env_flag?('LLA_WIDGET_GEOIP_ENABLED')
    )
  end

  def geo_client_ip
    Lla::Widget::TrustedClientIp.resolve(remote_ip: request.remote_ip, remote_addr: request.remote_addr)
  end

  def audit_geo_decision(result:, country: nil, error_code: nil)
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
