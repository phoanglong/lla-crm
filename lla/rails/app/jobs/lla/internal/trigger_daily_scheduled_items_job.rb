# frozen_string_literal: true

# Nối vào job kích hoạt hằng ngày của CE (prepend_mod_with) để lên lịch
# auto-sync tài liệu LLA AI theo nhịp gói: enterprise mỗi ngày, business
# Chủ nhật hằng tuần, startups ngày đầu tháng.
module Lla::Internal::TriggerDailyScheduledItemsJob
  def perform
    super
    schedule_captain_document_syncs
  end

  private

  def schedule_captain_document_syncs
    today = Time.current.utc

    Captain::Documents::ScheduleSyncsJob.perform_later('enterprise')
    Captain::Documents::ScheduleSyncsJob.perform_later('business') if today.sunday?
    Captain::Documents::ScheduleSyncsJob.perform_later('startups') if today.day == 1
  end
end
