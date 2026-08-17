module Enterprise::PortalPolicy
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
