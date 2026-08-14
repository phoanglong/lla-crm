# frozen_string_literal: true

# Vai trò tuỳ chỉnh ở cấp tài khoản — năng lực do LLA phát triển (ADR-OMCRM-032).
#
# Bảng custom_roles và cột account_users.custom_role_id nằm trong db/schema.rb
# (phần MIT của repo). Danh sách quyền lấy từ hợp đồng giao diện MIT:
# app/javascript/dashboard/constants/permissions.js — AVAILABLE_CUSTOM_ROLE_PERMISSIONS.
class CustomRole < ApplicationRecord
  # Giữ đúng thứ tự và tên như hằng ở phía frontend; frontend là bên tiêu thụ nên
  # đây là hợp đồng, không phải lựa chọn tự do.
  PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
    contact_manage
    report_manage
    knowledge_base_manage
  ].freeze

  # Quyền hội thoại xếp theo mức rộng dần: quyền đứng trước bao trùm quyền sau.
  CONVERSATION_PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
  ].freeze

  belongs_to :account
  has_many :account_users, dependent: :nullify

  validates :name, presence: true
  validate :validate_permission_names

  private

  def validate_permission_names
    return if permissions.blank?

    unknown = permissions.map(&:to_s) - PERMISSIONS
    return if unknown.empty?

    errors.add(:permissions, "không hợp lệ: #{unknown.join(', ')}")
  end
end
