# frozen_string_literal: true

# LLA replacement for the Chatwoot Cloud `ssl_status` slice, plus the two things the
# lifecycle needs at the API boundary: field-level authorization for the custom
# domain, and an administrator-triggered reverification for legacy imports.
#
# `ssl_status` reports the LLA lifecycle rather than proxying a live provider call,
# so the endpoint works with the provider disabled, performs no egress, and never
# returns an ownership token, provider error body or credential.
module Lla::Api::V1::Accounts::PortalsController
  # Changing a custom domain changes DNS/TLS-facing tenant state. It deliberately
  # does not ride on the portal *content* permission, which the enterprise policy
  # grants to any custom role holding `knowledge_base_manage`.
  def create
    return if reject_unauthorized_custom_domain_change?

    super
  end

  def update
    return if reject_unauthorized_custom_domain_change?

    super
  end

  def ssl_status
    return head :not_found if @portal.blank?

    render json: custom_domain_payload(@portal.lla_custom_domain)
  end

  # Administrator-triggered reverification of a legacy import. Bounded, idempotent
  # and tenant-scoped; it performs no egress by itself — the operation does, and only
  # when the capability and account consent allow it.
  def custom_domain_reverify
    return head :not_found if @portal.blank?
    return if reject_unauthorized_custom_domain_change?

    domain = @portal.lla_custom_domain
    return render_could_not_create_error(I18n.t('portals.ssl_status.custom_domain_not_configured')) if domain.blank?

    reverify_or_retry!(domain)
    render json: custom_domain_payload(domain.reload)
  rescue Lla::CustomDomains::LifecycleService::InvalidRequest => e
    render json: { error: e.code, error_code: e.code }, status: :unprocessable_entity
  end

  private

  # One administrator action, two lifecycle meanings: prove a legacy import that is
  # still serving, or make a genuinely new attempt at a claim whose proof never
  # arrived. Both are bounded and neither fabricates a proof.
  def reverify_or_retry!(domain)
    lifecycle = Lla::CustomDomains::LifecycleService.new(portal: @portal)
    return lifecycle.request_reverify!(domain) if lifecycle.reverifiable?(domain)
    return lifecycle.retry_verification!(domain) if lifecycle.retryable?(domain)

    raise Lla::CustomDomains::LifecycleService::InvalidRequest, 'lla_custom_domain_reverify_not_applicable'
  end

  def reject_unauthorized_custom_domain_change?
    return false unless custom_domain_change_requested?
    return false if Lla::CustomDomains::AuthorizationPolicy.manage?(Current.account_user)

    render json: { error: I18n.t('portals.custom_domain.forbidden'),
                   error_code: Lla::CustomDomains::AuthorizationPolicy::Denied.new.code },
           status: :forbidden
    true
  end

  # Only guards requests that actually try to move the domain: editing portal
  # content, or re-submitting the same canonical hostname, stays a content action.
  def custom_domain_change_requested?
    return true if action_name == 'custom_domain_reverify'
    return false unless params[:portal].is_a?(ActionController::Parameters)
    return false unless params[:portal].key?(:custom_domain)

    requested = canonical_requested_domain
    requested != guarded_portal&.custom_domain
  end

  # `@portal` is not necessarily this request's subject: `SwitchLocale` assigns it
  # from the `Host` header on every request, and `create` has no portal of its own.
  # The guard therefore compares only against a portal that belongs to the current
  # account and was fetched for this action.
  def guarded_portal
    return if action_name == 'create'
    return unless @portal.is_a?(::Portal)
    return unless @portal.account_id == Current.account&.id

    @portal
  end

  def canonical_requested_domain
    value = params[:portal][:custom_domain]
    return if value.blank?

    Lla::CustomDomains::HostCanonicalizer.from_user_input(value)
  rescue Lla::CustomDomains::HostCanonicalizer::InvalidHost
    # An unparseable value is still an attempted change, so it must be authorized
    # before the model gets a chance to reject it.
    value.to_s
  end

  # Exactly the payload the portal JSON already carries, so a refresh can never
  # disagree with what the page was rendered from. `status`/`verification_errors`
  # are kept for backwards compatibility with the existing client.
  def custom_domain_payload(_domain = nil)
    Lla::CustomDomains::StatusPresenter.call(portal: @portal.reload, account_user: Current.account_user)
  end
end
