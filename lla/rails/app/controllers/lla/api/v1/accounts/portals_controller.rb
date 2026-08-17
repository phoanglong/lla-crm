# frozen_string_literal: true

# LLA replacement for the Chatwoot Cloud `ssl_status` slice.
#
# It reports the LLA lifecycle rather than proxying a live Cloudflare call, so the
# endpoint works with the provider disabled, performs no egress, and never returns
# an ownership token, provider error body or credential.
module Lla::Api::V1::Accounts::PortalsController
  def ssl_status
    return head :not_found if @portal.blank?

    domain = @portal.lla_custom_domain
    return render_could_not_create_error(I18n.t('portals.ssl_status.custom_domain_not_configured')) if domain.blank?

    render json: {
      status: domain.provider_status.presence || domain.state,
      verification_errors: domain.last_error_code.to_s,
      custom_domain: domain.hostname,
      lifecycle_state: domain.state,
      provider: domain.provider,
      ownership_verified_at: domain.ownership_verified_at,
      activated_at: domain.activated_at,
      challenge_expires_at: domain.challenge_expires_at
    }
  end
end
