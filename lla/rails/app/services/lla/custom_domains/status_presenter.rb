# frozen_string_literal: true

# The single server-side answer to "what may this caller see and do with this
# portal's custom domain?".
#
# It exists so the dashboard never has to infer entitlement from hosting plan,
# provider status strings or the mere presence of a hostname: capability, provider
# readiness and the caller's own permission are stated explicitly, and the two
# administrator actions are booleans rather than something the client re-derives.
#
# It is deliberately pure: no provider call, no egress, no secret, no challenge
# material — only lifecycle facts that are safe for any caller allowed to read the
# portal.
class Lla::CustomDomains::StatusPresenter
  def self.call(portal:, account_user: nil)
    new(portal: portal, account_user: account_user).call
  end

  def initialize(portal:, account_user: nil)
    @portal = portal
    @account_user = account_user
  end

  def call
    return base if domain.blank?

    base.merge(configured: true, **lifecycle_fields, **action_fields)
  end

  private

  attr_reader :portal, :account_user

  def domain
    return @domain if defined?(@domain)

    @domain = portal.respond_to?(:lla_custom_domain) ? portal.lla_custom_domain : nil
  end

  def lifecycle
    @lifecycle ||= Lla::CustomDomains::LifecycleService.new(portal: portal)
  end

  def base
    {
      capability_enabled: Lla::Knowledge::ProviderPolicy.capability_enabled?(:custom_domains),
      provider_ready: Lla::CustomDomains::Providers::CloudflareProvider.available_for?(portal.account),
      can_manage: Lla::CustomDomains::AuthorizationPolicy.manage?(account_user),
      configured: false,
      status: nil,
      lifecycle_state: nil,
      verification_errors: '',
      reverify_available: false,
      retry_available: false
    }
  end

  def lifecycle_fields # rubocop:disable Metrics/AbcSize
    {
      status: domain.provider_status.presence || domain.state,
      verification_errors: domain.last_error_code.to_s,
      custom_domain: domain.hostname,
      lifecycle_state: domain.state,
      provider: domain.provider,
      ownership_source: domain.ownership_source,
      reverify_required: domain.reverify_required,
      manual_intervention_required:
        domain.last_error_code == Lla::CustomDomains::ReconciliationJob::MANUAL_INTERVENTION_CODE,
      ownership_verified_at: domain.ownership_verified_at,
      activated_at: domain.activated_at,
      challenge_expires_at: domain.challenge_expires_at
    }
  end

  def action_fields
    manageable = Lla::CustomDomains::AuthorizationPolicy.manage?(account_user)
    {
      reverify_available: manageable && lifecycle.reverifiable?(domain),
      retry_available: manageable && lifecycle.retryable?(domain)
    }
  end
end
