# TODO: we should switch to ActionController::API for the base classes
# One of the specs is failing when I tried doing that, lets revisit in future
class PublicController < ActionController::Base
  include RequestExceptionHandler
  skip_before_action :verify_authenticity_token

  private

  # Host lookup goes through the LLA custom-domain resolver: only a canonical host
  # with an active, tenant-bound lifecycle row resolves. The error never reflects
  # the submitted Host back to the caller and carries LLA product copy.
  def ensure_custom_domain_request
    return if DomainHelper.chatwoot_domain?(request.host)

    @portal = Lla::CustomDomains::HostResolver.portal_for(request.host)
    return if @portal.present?

    render json: {
      error: I18n.t('portals.custom_domain.not_registered'),
      error_code: 'lla_custom_domain_not_registered'
    }, status: :unauthorized and return
  end

  def ensure_portal_feature_enabled
    return unless ChatwootApp.chatwoot_cloud?
    return if @portal.account.feature_enabled?('help_center')

    render 'public/api/v1/portals/not_active', status: :payment_required
  end
end
