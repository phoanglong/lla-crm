# frozen_string_literal: true

# Field-level authorization for privileged portal settings owned by LLA (ADR-OMCRM-032).
# Content roles (knowledge_base_manage) may edit portal content, but changing the
# custom domain (a DNS/domain-lifecycle field) stays administrator-only. This keeps the
# content/custom-domain separation without touching the G4a portal concern.
module Lla::Api::V1::Accounts::PortalsController
  PRIVILEGED_PORTAL_FIELDS = %w[custom_domain].freeze

  def create
    authorize_privileged_portal_settings!
    super
  end

  def update
    authorize_privileged_portal_settings!
    super
  end

  private

  def authorize_privileged_portal_settings!
    return unless privileged_portal_settings_requested?
    return if Current.account_user&.administrator?

    raise Pundit::NotAuthorizedError
  end

  def privileged_portal_settings_requested?
    portal_settings = params[:portal]
    portal_settings.respond_to?(:key?) && PRIVILEGED_PORTAL_FIELDS.any? { |field| portal_settings.key?(field) }
  end
end
