class Internal::TriggerDailyScheduledItemsJob < ApplicationJob
  queue_as :scheduled_jobs

  # The hook the daily scheduler calls. Community has nothing to run here: the
  # only job this used to schedule was the version check, which asked Chatwoot's
  # hosted hub what the latest release was and paid for the answer by posting
  # this installation's metrics. Both are gone.
  #
  # LLA prepends its own `perform` onto this one, so the extension point is what
  # is load-bearing, not the body.
  def perform
    # No community daily jobs are registered.
  end
end

Internal::TriggerDailyScheduledItemsJob.prepend_mod_with('Internal::TriggerDailyScheduledItemsJob')
