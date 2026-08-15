# frozen_string_literal: true

# Chạy định kỳ: rải việc đánh giá SLA cho từng tài khoản có khai chính sách SLA.
class Sla::TriggerSlasForAccountsJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Account.joins(:sla_policies).distinct.find_each(batch_size: 100) do |account|
      Sla::ProcessAccountAppliedSlasJob.perform_later(account)
    end
  end
end
