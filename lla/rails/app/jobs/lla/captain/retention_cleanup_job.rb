# frozen_string_literal: true

class Lla::Captain::RetentionCleanupJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 1_000

  def perform(now = Time.current)
    purge(Captain::MessageReport.where(expires_at: ...now))
    purge(Lla::Captain::BulkOperation.where(expires_at: ...now))
  end

  private

  def purge(scope)
    # Retention is an intentional hard delete and must not enqueue dependent work.
    scope.in_batches(of: BATCH_SIZE).delete_all
  end
end
