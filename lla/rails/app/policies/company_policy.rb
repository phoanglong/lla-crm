# frozen_string_literal: true

# Agent làm việc trực tiếp với khách nên được đọc/tạo/sửa company; xoá là thao
# tác phá huỷ dữ liệu gộp — chỉ administrator.
class CompanyPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def create?
    true
  end

  def update?
    true
  end

  def search?
    true
  end

  def destroy_custom_attributes?
    true
  end

  def avatar?
    true
  end

  def destroy?
    @account_user.administrator?
  end
end
