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
  # Khoá hàng hội thoại (`FOR UPDATE SKIP LOCKED`) chỉ ngăn hai worker giành CÙNG
  # một hội thoại. Nó không ngăn hai worker giành HAI hội thoại KHÁC nhau cho cùng
  # một agent: hai transaction khoá hai hàng khác nhau, dưới READ COMMITTED cả hai
  # đọc được cùng một số đếm trước commit, cả hai đều lọt, và giới hạn của agent bị
  # vượt tới (số worker − 1). Đọc lại sức chứa sau khi khoá hội thoại chỉ thu hẹp
  # cửa sổ chứ không đóng được nó.
  #
  # Vì vậy phải tuần tự hoá theo (inbox, agent) — đúng thứ nguyên mà giới hạn được
  # định nghĩa — trước khi đọc tải của agent. Advisory lock ở phạm vi transaction:
  # tự nhả khi commit hoặc rollback, không để lại khoá mồ côi nếu worker chết.
  def claim_and_assign(conversation, agent)
    Current.executed_by = inbox.assignment_policy || inbox

    Conversation.transaction do
      lock_agent_capacity!(agent)

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

  # Khoá tuần tự cho một agent trong một inbox. Chỉ lấy khoá khi sức chứa thực sự
  # được cưỡng chế — tài khoản không bật advanced_assignment thì không có giới hạn
  # nào để bảo vệ, và tuần tự hoá khi ấy chỉ làm chậm.
  #
  # `hashtextextended` cho khoá 64 bit từ một chuỗi, nên id kiểu bigint không bị cắt
  # như khi dùng biến thể hai tham số int4 của `pg_advisory_xact_lock`. Tiền tố
  # `lla:` để không đụng khoá của thành phần khác trên cùng database.
  def lock_agent_capacity!(agent)
    return unless inbox.account.feature_enabled?('advanced_assignment')

    Conversation.connection.execute(
      Conversation.sanitize_sql_array(
        ['SELECT pg_advisory_xact_lock(hashtextextended(?, 0))', agent_capacity_lock_key(agent)]
      )
    )
  end

  def agent_capacity_lock_key(agent)
    "lla:auto_assignment:capacity:#{inbox.id}:#{agent.id}"
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
