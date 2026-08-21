# frozen_string_literal: true

# Duyệt FAQ là việc vận hành hằng ngày — mọi thành viên account làm được;
# phạm vi nhìn thấy đã siết ở controller theo inbox membership.
class Captain::FaqSuggestionPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def update?
    true
  end

  def approve?
    true
  end

  def dismiss?
    true
  end
end
