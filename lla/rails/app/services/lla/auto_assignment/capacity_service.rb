# frozen_string_literal: true

# Trả lời một câu hỏi duy nhất: agent này còn chỗ nhận hội thoại ở inbox này không.
#
# Quy tắc (hợp đồng từ spec MIT spec/enterprise/services/.../capacity_service_spec.rb,
# đã chuyển sang spec/lla):
# - Agent không thuộc chính sách nào → không giới hạn.
# - Chính sách không đặt giới hạn cho inbox này → không giới hạn ở inbox này.
# - Có giới hạn → so số hội thoại OPEN đang gán cho agent trong inbox với giới hạn;
#   giới hạn 0 nghĩa là loại trừ hẳn (0 < 0 luôn sai).
class Lla::AutoAssignment::CapacityService
  def agent_has_capacity?(user, inbox)
    policy = user.account_users.find_by(account_id: inbox.account_id)&.agent_capacity_policy
    return true if policy.blank?

    limit = policy.inbox_capacity_limits.find_by(inbox_id: inbox.id)
    return true if limit.blank?

    user.assigned_conversations.where(inbox_id: inbox.id, status: :open).count < limit.conversation_limit
  end
end
