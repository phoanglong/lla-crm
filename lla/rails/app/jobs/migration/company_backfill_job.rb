# frozen_string_literal: true

# Backfill company cho dữ liệu contact có sẵn: rải một job theo từng tài khoản.
class Migration::CompanyBackfillJob < ApplicationJob
  queue_as :low

  def perform
    Account.find_each(batch_size: 100) do |account|
      Migration::CompanyAccountBatchJob.perform_later(account)
    end
  end
end
