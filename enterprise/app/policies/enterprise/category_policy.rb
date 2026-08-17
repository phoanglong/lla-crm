module Enterprise::CategoryPolicy
  KB_MANAGE_PERMISSION = 'knowledge_base_manage'.freeze

  def index?
    custom_role_can_manage_kb? || super
  end

  def update?
    (custom_role_can_manage_kb? && record_within_account?) || super
  end

  def show?
    (custom_role_can_manage_kb? && record_within_account?) || super
  end

  def edit?
    (custom_role_can_manage_kb? && record_within_account?) || super
  end

  def create?
    custom_role_can_manage_kb? || super
  end

  def destroy?
    (custom_role_can_manage_kb? && record_within_account?) || super
  end

  def reorder?
    custom_role_can_manage_kb? || super
  end

  private

  def custom_role_can_manage_kb?
    context_consistent? && @account_user.custom_role&.permissions&.include?(KB_MANAGE_PERMISSION)
  end

  def context_consistent?
    return false unless @user.present? && @account.present? && @account_user.present?
    return false unless @account_user.account_id == @account.id
    return false unless @account_user.user_id == @user.id

    custom_role = @account_user.custom_role
    custom_role.present? && custom_role.account_id == @account.id
  end

  def record_within_account?
    return true unless @record.respond_to?(:account_id)

    @record.account_id == @account.id
  end
end
