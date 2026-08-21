# frozen_string_literal: true

class Lla::Captain::QuotaReconciliationJob < ApplicationJob
  queue_as :scheduled_jobs

  MAX_LEDGERS_PER_RUN = 1_000

  def perform
    reconciliation_scope.limit(MAX_LEDGERS_PER_RUN).find_each do |ledger|
      Lla::Captain::QuotaReconciliationService.new(ledger).perform
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: ledger.account).capture_exception
      Rails.logger.error("LLA Captain quota reconciliation failed ledger_id=#{ledger.id} error=#{e.class.name}")
    end
  end

  private

  def reconciliation_scope
    stale_ledger_ids = Lla::Captain::QuotaReservation.reserved
                                                     .where('claimed_at < ?', Lla::Captain::QuotaReconciliationService::STALE_AFTER.ago)
                                                     .select(:quota_ledger_id)
    Lla::Captain::QuotaLedger.where(reconciliation_state: %i[pending drifted])
                             .or(Lla::Captain::QuotaLedger.where(id: stale_ledger_ids))
                             .where('period_end > ?', 2.months.ago)
                             .distinct
  end
end
