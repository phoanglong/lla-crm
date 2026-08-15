# frozen_string_literal: true

# Đánh giá một AppliedSla tại thời điểm hiện tại: ghi nhận các lần lỡ hạn và
# chốt trạng thái khi hội thoại resolved.
#
# Hợp đồng từ spec MIT spec/enterprise/services/sla/evaluate_applied_sla_service_spec.rb
# (đã chuyển sang spec/lla):
# - Contact bị chặn → không đánh giá gì.
# - frt/rt lỡ hạn ghi nhận MỘT lần (đã có sự kiện thì thôi); nrt ghi nhận MỖI
#   lượt đánh giá còn quá hạn — mỗi lượt khách chờ là một lần lỡ đáng báo.
# - rt chỉ xét khi hội thoại còn mở: resolved trễ chút ít không bị tính missed.
# - Khi resolved: có sự kiện lỡ → missed; sạch → hit (log info).
class Sla::EvaluateAppliedSlaService
  pattr_initialize [:applied_sla!]

  def perform
    return unless conversation.sla_applicable?

    check_frt
    check_nrt
    check_rt
    finalize_status
  end

  private

  delegate :conversation, :sla_policy, to: :applied_sla

  def check_frt
    return if applied_sla.frt_due_at.blank?
    return if applied_sla.sla_events.frt.exists?

    responded_at = conversation.first_reply_created_at
    missed = responded_at.present? ? responded_at.to_i > applied_sla.frt_due_at : Time.zone.now.to_i > applied_sla.frt_due_at
    record_miss('frt') if missed
  end

  def check_nrt
    return if applied_sla.nrt_due_at.blank?

    record_miss('nrt') if Time.zone.now.to_i > applied_sla.nrt_due_at
  end

  def check_rt
    return if conversation.resolved?
    return if applied_sla.rt_due_at.blank?
    return if applied_sla.sla_events.rt.exists?

    record_miss('rt') if Time.zone.now.to_i > applied_sla.rt_due_at
  end

  def record_miss(event_type)
    applied_sla.sla_events.create!(event_type: event_type, conversation: conversation)
    Rails.logger.warn("SLA #{event_type} missed for conversation #{conversation.id} in account " \
                      "#{applied_sla.account_id} for sla_policy #{sla_policy.id}")
  end

  def finalize_status
    if conversation.resolved?
      finalize_resolved_status
    elsif misses? && !applied_sla.active_with_misses?
      applied_sla.update!(sla_status: :active_with_misses)
    end
  end

  def finalize_resolved_status
    if misses?
      applied_sla.update!(sla_status: :missed)
    else
      applied_sla.update!(sla_status: :hit)
      Rails.logger.info("SLA hit for conversation #{conversation.id} in account " \
                        "#{applied_sla.account_id} for sla_policy #{sla_policy.id}")
    end
  end

  def misses?
    applied_sla.sla_events.exists?
  end
end
