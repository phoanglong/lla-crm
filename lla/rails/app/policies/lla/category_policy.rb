# frozen_string_literal: true

# Least-privilege knowledge-base authorization owned by LLA (ADR-OMCRM-032).
# Prepended to the MIT CategoryPolicy via prepend_mod_with; wins over Enterprise::
# because ChatwootApp.extensions orders 'lla' last.
#
# The tenant guard wraps BOTH the custom-role grant and the base `super` result, so a
# stale/forged context or an administrator from another account can never authorize a
# record outside their own tenant.
module Lla::CategoryPolicy
  KB_MANAGE_PERMISSION = 'knowledge_base_manage'

  def index?
    scoped_context? && (custom_role_can_manage_kb? || super)
  end

  def create?
    scoped_context? && (custom_role_can_manage_kb? || super)
  end

  def reorder?
    scoped_context? && (custom_role_can_manage_kb? || super)
  end

  def update?
    record_authorized? && (custom_role_can_manage_kb? || super)
  end

  def show?
    record_authorized? && (custom_role_can_manage_kb? || super)
  end

  def edit?
    record_authorized? && (custom_role_can_manage_kb? || super)
  end

  def destroy?
    record_authorized? && (custom_role_can_manage_kb? || super)
  end

  private

  def record_authorized?
    scoped_context? && record_within_account?
  end

  def scoped_context?
    @user.present? && @account.present? && @account_user.present? &&
      @account_user.account_id == @account.id && @account_user.user_id == @user.id
  end

  def custom_role_can_manage_kb?
    role = @account_user&.custom_role
    role.present? && role.account_id == @account.id && role.permissions&.include?(KB_MANAGE_PERMISSION)
  end

  def record_within_account?
    return true unless @record.respond_to?(:account_id)

    @record.account_id == @account.id
  end
end
