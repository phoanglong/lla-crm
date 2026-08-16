# frozen_string_literal: true

class Captain::CustomToolPolicy < ApplicationPolicy
  def index?
    account_user.present?
  end

  def show?
    account_record?
  end

  def create?
    administrator? && account_record?
  end

  alias test? create?
  alias update? create?
  alias destroy? create?

  private

  def administrator?
    account_user&.administrator?
  end

  def account_record?
    record.respond_to?(:account_id) && record.account_id == account.id
  end
end
