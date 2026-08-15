# frozen_string_literal: true

# Nối việc đánh giá SLA định kỳ vào job lập lịch chung của CE.
# Prepend qua `TriggerScheduledItemsJob.prepend_mod_with('TriggerScheduledItemsJob')`.
module Lla::TriggerScheduledItemsJob
  def perform
    super

    Sla::TriggerSlasForAccountsJob.perform_later
  end
end
