# frozen_string_literal: true

# Bulk contact movement — import and export — is an administrator action, or a
# custom role holding `contact_manage`.
module Lla::ContactPolicy
  include Lla::CustomRolePermissions

  def export?
    custom_role_permits?('contact_manage') || super
  end

  def import?
    custom_role_permits?('contact_manage') || super
  end
end
