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

  # Chọn selector theo assignment policy của inbox. Chính sách `balanced` chọn agent
  # đang gánh ít hội thoại mở nhất; mặc định vẫn là round robin. Chính sách của tài
  # khoản khác hoặc đang tắt thì không được đổi hành vi — rơi về mặc định.
  def selector
    policy = inbox.assignment_policy
    return round_robin_selector if policy.blank?
    return round_robin_selector unless policy.account_id == inbox.account_id
    return round_robin_selector unless policy.enabled?
    return round_robin_selector unless policy.balanced?

    balanced_selector
  end

  def balanced_selector
    @balanced_selector ||= Lla::AutoAssignment::BalancedSelector.new(inbox: inbox)
  end

  def find_available_agent(conversation = nil)
    agents = filter_agents_by_team(inbox.available_agents, conversation)
    return nil if agents.nil?

    agents = filter_agents_by_rate_limit(agents)
    return nil if agents.empty?

    selector.select_agent(agents)
  end

  # Chốt hội thoại và kiểm tra lại sức chứa TRONG cùng transaction.
  #
  # `find_available_agent` lọc theo sức chứa trước khi chọn, nhưng giữa lúc chọn và
  # lúc ghi, một worker khác có thể đã gán hội thoại khác cho đúng agent đó. Khoá
  # hàng hội thoại chỉ ngăn hai worker gán cùng một hội thoại; nó không ngăn hai
  # worker cùng đẩy một agent vượt giới hạn. Đọc lại số hội thoại mở của agent sau
  # khi đã khoá thì lần đọc đó nằm sau mọi commit trước, nên vượt giới hạn bị từ
  # chối thay vì được ghi.
  def claim_and_assign(conversation, agent)
    Current.executed_by = inbox.assignment_policy || inbox

    Conversation.transaction do
      locked = inbox.conversations
                    .where(id: conversation.id, assignee_id: nil)
                    .lock('FOR UPDATE SKIP LOCKED')
                    .first
      next false unless locked
      next false unless agent_still_has_capacity?(agent)

      locked.update!(assignee: agent)
      true
    end
  ensure
    Current.executed_by = nil
  end

  def agent_still_has_capacity?(agent)
    return true unless inbox.account.feature_enabled?('advanced_assignment')

    Lla::AutoAssignment::CapacityService.new.agent_has_capacity?(agent, inbox)
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
