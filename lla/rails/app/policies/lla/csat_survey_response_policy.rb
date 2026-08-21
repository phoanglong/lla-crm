# frozen_string_literal: true

# CSAT review is reporting: an administrator, or a custom role holding
# `report_manage`. `update?` is deliberately not `|| super` — the community policy
# has no `update?` of its own, and `ApplicationPolicy#update?` is `false`, so
# spelling it out here keeps the answer from depending on that.
module Lla::CsatSurveyResponsePolicy
  include Lla::CustomRolePermissions

  def index?
    custom_role_permits?('report_manage') || super
  end

  def metrics?
    custom_role_permits?('report_manage') || super
  end

  def download?
    custom_role_permits?('report_manage') || super
  end

  def update?
    account_user&.administrator? || custom_role_permits?('report_manage')
  end
end
