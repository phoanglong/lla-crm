# frozen_string_literal: true

module Lla::Internal::TriggerHourlyScheduledItemsJob
  def perform
    super
    Lla::Captain::QuotaReconciliationJob.perform_later
  end
end
