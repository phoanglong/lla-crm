# frozen_string_literal: true

# Chen bước lọc theo tải vào auto-assignment v2: agent hết chỗ (theo
# Lla::AutoAssignment::CapacityService) không được đưa vào round robin.
#
# Móc vào filter_agents_by_rate_limit thay vì viết lại find_available_agent:
# hai bước lọc độc lập và giao hoán, còn phần chọn agent giữ nguyên của CE.
module Lla::AutoAssignment::AssignmentService
  private

  def filter_agents_by_rate_limit(agents)
    super(filter_agents_by_capacity(agents))
  end

  # Luật loại trừ của chính sách tải (theo nhãn / theo tuổi hội thoại):
  # hội thoại khớp luật thì auto-assignment bỏ qua, để agent tự nhận.
  def assignable?(conversation)
    super && !excluded_by_capacity_rules?(conversation)
  end

  def excluded_by_capacity_rules?(conversation)
    exclusion_rule_sets.any? do |rules|
      excluded_by_labels?(conversation, rules['excluded_labels']) ||
        excluded_by_age?(conversation, rules['exclude_older_than_hours'])
    end
  end

  def exclusion_rule_sets
    @exclusion_rule_sets ||= AgentCapacityPolicy
                             .joins(:inbox_capacity_limits)
                             .where(inbox_capacity_limits: { inbox_id: inbox.id })
                             .filter_map { |policy| policy.exclusion_rules.presence }
  end

  def excluded_by_labels?(conversation, excluded_labels)
    return false if excluded_labels.blank?

    conversation.label_list.intersect?(excluded_labels)
  end

  def excluded_by_age?(conversation, hours)
    return false if hours.blank?

    conversation.last_activity_at.present? && conversation.last_activity_at < hours.to_i.hours.ago
  end

  # Chỉ cưỡng chế khi tài khoản còn bật advanced_assignment: tài khoản đã hạ cấp
  # nhưng còn chính sách cũ trong DB thì không được âm thầm chặn assignment.
  def filter_agents_by_capacity(agents)
    return agents unless inbox.account.feature_enabled?('advanced_assignment')

    capacity_service = Lla::AutoAssignment::CapacityService.new
    agents.select { |inbox_member| capacity_service.agent_has_capacity?(inbox_member.user, inbox) }
  end
end
