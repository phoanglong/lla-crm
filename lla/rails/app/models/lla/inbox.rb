# frozen_string_literal: true

# Năng lực tải (capacity) trên Inbox. Prepend qua `Inbox.prepend_mod_with('Inbox')`
# (MIT app/models/inbox.rb) — phải prepend vào chính Inbox vì
# member_ids_with_assignment_capacity được định nghĩa ngay trong class (che bản
# trong concern InboxAgentAvailability).
#
# Hợp đồng từ spec MIT spec/enterprise/models/inbox_spec.rb (đã chuyển sang
# spec/lla/models/inbox_capacity_spec.rb):
# - assignment_v2 + advanced_assignment bật → lọc theo chính sách tải LLA trên
#   tập agent online, bỏ qua max_assignment_limit kiểu V1.
# - Ngược lại, inbox có max_assignment_limit → loại thành viên đã đạt số hội
#   thoại open bằng giới hạn.
# - Không cấu hình gì → toàn bộ thành viên (hành vi CE).
# - max_assignment_limit nếu khai phải là số nguyên dương.
module Lla::Inbox
  def active_bot?
    super || captain_active?
  end

  def captain_active?
    assistant = captain_assistant
    return false if assistant.blank? || assistant.account_id != account_id

    account.usage_limits.dig(:captain, :responses, :current_available).to_i.positive?
  end

  def member_ids_with_assignment_capacity
    if auto_assignment_v2_enabled? && account.feature_enabled?('advanced_assignment')
      capacity_service = Lla::AutoAssignment::CapacityService.new
      available_agents.select { |inbox_member| capacity_service.agent_has_capacity?(inbox_member.user, self) }
                      .map(&:user_id)
    elsif enable_auto_assignment? && max_assignment_limit.present?
      # Giới hạn V1 chỉ áp cho auto-assignment của inbox; gán qua team khi inbox
      # tắt auto-assignment thì không bị chặn (spec conversation_sla).
      members.ids - member_ids_at_max_assignment_limit
    else
      # Hành vi CE (app/models/inbox.rb): toàn bộ thành viên. Không gọi super:
      # trong giai đoạn chuyển tiếp EE ON, super rơi vào Enterprise::Inbox vốn
      # phụ thuộc helper EE đã bị gỡ trong wave này.
      members.ids
    end
  end

  def max_assignment_limit
    auto_assignment_config['max_assignment_limit']
  end

  private

  def ensure_valid_max_assignment_limit
    return if max_assignment_limit.nil?
    return if max_assignment_limit.to_i.positive?

    errors.add(:auto_assignment_config, 'max_assignment_limit must be a positive integer')
  end

  def member_ids_at_max_assignment_limit
    conversations.open
                 .where(assignee_id: members.ids)
                 .group(:assignee_id)
                 .having('count(*) >= ?', max_assignment_limit.to_i)
                 .pluck(:assignee_id)
  end
end
