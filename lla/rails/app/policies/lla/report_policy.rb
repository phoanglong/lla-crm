# frozen_string_literal: true

# Reporting is visible to an administrator, or to a custom role that has been
# granted `report_manage`.
module Lla::ReportPolicy
  include Lla::CustomRolePermissions

  def view?
    custom_role_permits?('report_manage') || super
  end
end
