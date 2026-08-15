# frozen_string_literal: true

# Cho template liquid (email lỡ hạn SLA) đọc tên và mô tả chính sách.
class SlaPolicyDrop < BaseDrop
  delegate :name, :description, to: :@obj
end
