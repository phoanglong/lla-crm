# frozen_string_literal: true

# Gắn SLA vào Conversation. Prepend qua `Conversation.prepend_mod_with('Conversation')`
# (MIT app/models/conversation.rb).
#
# Hợp đồng từ spec MIT spec/enterprise/models/conversation_spec.rb (đã chuyển
# sang spec/lla): SLA của tài khoản khác bị từ chối; đã có SLA thì không đổi và
# không gỡ; contact bị chặn thì không gán; gán xong tạo AppliedSla. Phần thông
# điệp hoạt động "added SLA policy" do máy móc MIT (SlaActivityMessageHandler)
# đảm nhiệm sẵn.
module Lla::Conversation
  extend ActiveSupport::Concern

  prepended do
    belongs_to :sla_policy, optional: true
    has_one :applied_sla, dependent: :destroy_async
    has_many :sla_events, dependent: :destroy_async

    validate :validate_sla_policy_change, if: :sla_policy_id_changed?

    after_save :create_applied_sla, if: :saved_change_to_sla_policy_id?
  end

  # Frontend và các luồng SLA chỉ đối xử với hội thoại còn "chạm được".
  # Contact không còn (dữ liệu cũ) vẫn tính; contact bị chặn thì không.
  def sla_applicable?
    contact.blank? || !contact.blocked?
  end

  private

  def validate_sla_policy_change
    return validate_existing_sla_change if sla_policy_id_was.present?
    return if sla_policy_id.blank?

    errors.add(:sla_policy, 'sla policy account mismatch') if sla_policy && sla_policy.account_id != account_id
    errors.add(:sla_policy, 'cannot be assigned to conversations with blocked contacts') unless sla_applicable?
  end

  def validate_existing_sla_change
    errors.add(:sla_policy, 'conversation already has a different sla') if sla_policy_id.present?
    errors.add(:sla_policy, 'cannot remove sla policy from conversation') if sla_policy_id.blank?
  end

  def create_applied_sla
    return if sla_policy_id.blank?

    AppliedSla.find_or_create_by!(account: account, sla_policy_id: sla_policy_id, conversation: self)
  end
end
