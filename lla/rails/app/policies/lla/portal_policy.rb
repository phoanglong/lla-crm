# frozen_string_literal: true

# Portal write authorization owned by LLA (ADR-OMCRM-032). Prepended to the MIT
# PortalPolicy via prepend_mod_with. Preserves the knowledge_base_manage grant for
# portal content management but wraps every result in the tenant guard so a forged
# context or a cross-account administrator cannot write another tenant's portal.
# Custom-domain/DNS lifecycle stays owned by the G4a portal concern, not this policy.
module Lla::PortalPolicy
  KB_MANAGE_PERMISSION = 'knowledge_base_manage'

  def update?
    record_authorized? && (custom_role_can_manage_kb? || super)
  end

  def edit?
    record_authorized? && (custom_role_can_manage_kb? || super)
  end

  def logo?
    record_authorized? && (custom_role_can_manage_kb? || super)
  end

  # Custom-domain reverification changes DNS/TLS-facing tenant state, so it keeps the
  # base administrator-only grant and deliberately does NOT accept the content
  # permission — but it still passes through the same tenant guard as every other
  # action here, so a stale or forged context cannot reach it.
  def custom_domain_reverify?
    record_authorized? && super
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
