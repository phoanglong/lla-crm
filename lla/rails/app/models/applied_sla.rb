# frozen_string_literal: true

# Bản ghi SLA đã áp lên một hội thoại. `sla_status` đi theo vòng đời:
# active → active_with_misses (lỡ hạn khi còn mở) → hit/missed (khi resolved).
class AppliedSla < ApplicationRecord
  belongs_to :account
  belongs_to :sla_policy
  belongs_to :conversation

  has_many :sla_events, dependent: :destroy_async

  enum sla_status: { active: 0, hit: 1, missed: 2, active_with_misses: 3 }

  # SLA chỉ có nghĩa với hội thoại còn "chạm được": contact bị chặn thì bỏ qua,
  # contact không còn (dữ liệu cũ) thì vẫn tính.
  scope :with_sla_applicable_conversation, lambda {
    left_outer_joins(conversation: :contact).where(contacts: { blocked: [nil, false] })
  }

  def push_event_data
    {
      id: id,
      sla_id: sla_policy_id,
      sla_status: sla_status,
      created_at: created_at.to_i,
      updated_at: updated_at.to_i,
      sla_description: sla_policy.description,
      sla_name: sla_policy.name,
      sla_first_response_time_threshold: sla_policy.first_response_time_threshold,
      sla_next_response_time_threshold: sla_policy.next_response_time_threshold,
      sla_only_during_business_hours: sla_policy.only_during_business_hours,
      sla_resolution_time_threshold: sla_policy.resolution_time_threshold,
      sla_frt_due_at: frt_due_at,
      sla_nrt_due_at: nrt_due_at,
      sla_rt_due_at: rt_due_at
    }
  end

  def frt_due_at
    return if sla_policy.first_response_time_threshold.blank?

    calculate_due_at(conversation.created_at, sla_policy.first_response_time_threshold)
  end

  def nrt_due_at
    return if sla_policy.next_response_time_threshold.blank?
    return if conversation.waiting_since.blank?

    calculate_due_at(conversation.waiting_since, sla_policy.next_response_time_threshold)
  end

  def rt_due_at
    return if sla_policy.resolution_time_threshold.blank?

    calculate_due_at(conversation.created_at, sla_policy.resolution_time_threshold)
  end

  private

  def calculate_due_at(start_time, threshold_seconds)
    return (start_time + threshold_seconds).to_i unless sla_policy.only_during_business_hours?

    Sla::BusinessHoursService.new(
      inbox: conversation.inbox,
      start_time: start_time,
      threshold_seconds: threshold_seconds,
      working_hours_by_day: working_hours_by_day
    ).deadline.to_i
  end

  # Ba hạn (frt/nrt/rt) dùng chung một lần nạp giờ làm việc — tránh ba lượt
  # index_by khi serialize push_event_data.
  def working_hours_by_day
    @working_hours_by_day ||= conversation.inbox.working_hours.index_by(&:day_of_week)
  end
end
