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

  # Chỉ cưỡng chế khi tài khoản còn bật advanced_assignment: tài khoản đã hạ cấp
  # nhưng còn chính sách cũ trong DB thì không được âm thầm chặn assignment.
  def filter_agents_by_capacity(agents)
    return agents unless inbox.account.feature_enabled?('advanced_assignment')

    capacity_service = Lla::AutoAssignment::CapacityService.new
    agents.select { |inbox_member| capacity_service.agent_has_capacity?(inbox_member.user, inbox) }
  end
end
