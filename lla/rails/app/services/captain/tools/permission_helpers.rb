# frozen_string_literal: true

module Captain::Tools::PermissionHelpers
  MAX_OUTPUT_BYTES = 32_000
  MAX_RESULT_COUNT = 10
  MAX_QUERY_BYTES = 512

  private

  def account_user
    return if @assistant.blank? || @user.blank?

    @account_user ||= AccountUser.find_by(account_id: @assistant.account_id, user_id: @user.id)
  end

  def user_has_permission(permission)
    return false if account_user.blank?

    custom_role = account_user.custom_role
    return custom_role.permissions.include?(permission) if custom_role.present?

    account_user.administrator? || account_user.agent?
  end

  def administrator?
    account_user&.administrator? || false
  end

  def bounded_output(value)
    value.to_s.byteslice(0, MAX_OUTPUT_BYTES).to_s.scrub
  end

  def bounded_query(value)
    value.to_s.squish.byteslice(0, MAX_QUERY_BYTES).to_s.scrub
  end

  def meaningful_query?(value)
    bounded_query(value).scan(/[[:alnum:]]/).length >= 2
  end
end
