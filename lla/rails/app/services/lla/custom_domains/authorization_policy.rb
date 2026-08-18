# frozen_string_literal: true

# Field-level authorization for the custom-domain lifecycle.
#
# `PortalPolicy#update?` is a *content* permission: with the enterprise extension a
# custom role holding `knowledge_base_manage` can update a portal, and the portal
# update payload happens to carry `custom_domain`. Changing a custom domain changes
# DNS/TLS-facing tenant state, so it deliberately does **not** ride on that content
# permission — it requires an administrator of the same tenant.
#
# The narrower per-permission split (a dedicated `custom_domain_manage`) is a G5
# entitlement decision; until then the safe default is administrator-only, which is
# strictly less privilege than the inherited content permission.
class Lla::CustomDomains::AuthorizationPolicy
  class Denied < StandardError
    attr_reader :code

    def initialize(code = 'lla_custom_domain_forbidden')
      @code = code
      super(code)
    end
  end

  def self.manage?(account_user)
    return false if account_user.blank?

    account_user.administrator?
  end

  def self.authorize_manage!(account_user)
    return true if manage?(account_user)

    raise Denied
  end

  # Same tenant *and* administrator. Used wherever a portal is resolved from params.
  def self.manage_portal?(account_user, portal)
    return false if portal.blank?
    return false unless manage?(account_user)

    portal.account_id == account_user.account_id
  end
end
