# frozen_string_literal: true

module Lla::Internal::TriggerHourlyScheduledItemsJob
  def perform
    super
    Lla::Captain::QuotaReconciliationJob.perform_later
    Lla::Voice::OperationReconciliationJob.perform_later
    Lla::Knowledge::GenerationReconciliationJob.perform_later
    Twilio::VoiceLifecycleRepairJob.perform_later
    Whatsapp::CallingLifecycleRepairJob.perform_later
  end
end
