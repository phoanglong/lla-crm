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

  # Filtered unread counts are derived from `account_user.permissions`, which comes
  # from this role, and their freshness is decided by a per-(account, user) version
  # stamp. Changing a role's permissions — or deleting the role — therefore has to
  # bump that stamp, or every holder keeps validating counts computed under the old
  # permission set as fresh. `dependent: :nullify` detaches through `update_all` and
  # fires no callback on `AccountUser`, so nothing else covers the deletion case;
  # the user ids have to be captured before the detach happens.
  before_destroy :capture_filtered_unread_count_user_ids, prepend: true
  after_update_commit :invalidate_filtered_unread_count_visibility_update, if: :filtered_unread_count_permissions_changed?
  after_destroy_commit :invalidate_filtered_unread_count_visibility_destroy

  validates :name, presence: true
  validate :validate_permission_names

  private

  def filtered_unread_count_permissions_changed?
    previous_changes.key?('permissions')
  end

  def capture_filtered_unread_count_user_ids
    @filtered_unread_count_user_ids = account_users.pluck(:user_id)
  end

  def invalidate_filtered_unread_count_visibility_update
    invalidate_filtered_unread_count_visibility(account_users.pluck(:user_id))
  end

  def invalidate_filtered_unread_count_visibility_destroy
    invalidate_filtered_unread_count_visibility(@filtered_unread_count_user_ids)
  end

  def invalidate_filtered_unread_count_visibility(user_ids)
    invalidator = ::Conversations::UnreadCounts::FilteredCountInvalidator.new(account)
    visibility_changed = invalidator.users_visibility_changed!(user_ids: user_ids)

    dispatch_account_cache_invalidated if visibility_changed
  end

  def dispatch_account_cache_invalidated
    Rails.configuration.dispatcher.dispatch(ACCOUNT_CACHE_INVALIDATED, Time.zone.now,
                                            account: account, cache_keys: account.cache_keys)
  end

  def validate_permission_names
    return if permissions.blank?

    unknown = permissions.map(&:to_s) - PERMISSIONS
    return if unknown.empty?

    errors.add(:permissions, "không hợp lệ: #{unknown.join(', ')}")
  end
end
