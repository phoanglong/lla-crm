# frozen_string_literal: true

# Portal write authorization owned by LLA (ADR-OMCRM-032). Prepended to the MIT
# PortalPolicy via prepend_mod_with. Deliberately does NOT grant knowledge_base_manage
# custom roles portal write access: content editors must not change portal settings or
# custom-domain/DNS lifecycle. Only the administrator path in super is honoured, and
# only after re-applying account/tenant boundary defensively.
module Lla::PortalPolicy
  def update?
    context_consistent? && record_within_account? && super
  end

  def edit?
    context_consistent? && record_within_account? && super
  end

  def logo?
    context_consistent? && record_within_account? && super
  end

  private

  def context_consistent?
    return false unless @user.present? && @account.present? && @account_user.present?
    return false unless @account_user.account_id == @account.id

    @account_user.user_id == @user.id
  end

  def record_within_account?
    return true unless @record.respond_to?(:account_id)

    @record.account_id == @account.id
  end
end
