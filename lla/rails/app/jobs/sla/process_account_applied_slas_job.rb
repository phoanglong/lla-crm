# frozen_string_literal: true

# Đánh giá mọi AppliedSla còn hiệu lực của một tài khoản. hit/missed là trạng
# thái chung cuộc nên bỏ qua; contact bị chặn cũng bỏ qua từ đây cho đỡ tốn job.
class Sla::ProcessAccountAppliedSlasJob < ApplicationJob
  queue_as :medium

  def perform(account)
    account.applied_slas
           .where(sla_status: [:active, :active_with_misses])
           .with_sla_applicable_conversation
           .find_each(batch_size: 100) do |applied_sla|
      Sla::ProcessAppliedSlaJob.perform_later(applied_sla)
    end
  end
end
