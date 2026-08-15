# frozen_string_literal: true

# Bộ lập lịch auto-sync tài liệu web: chọn tài liệu đến hạn theo nhịp của gói
# (CAPTAIN_DOCUMENT_AUTO_SYNC_INTERVALS, giờ), rải đều bằng jitter ngẫu nhiên
# và chặn số lượng theo account/toàn hệ thống.
class Captain::Documents::ScheduleSyncsJob < ApplicationJob
  queue_as :scheduled_jobs

  # Trễ ngẫu nhiên tối đa khi thực thi sync — đồng thời NỚI cửa sổ đến hạn
  # (cutoff = nhịp - jitter) để lần chạy sau không bỏ sót tài liệu đã bị trễ.
  WEEKLY_SYNC_JITTER = 3.5.days
  # Đang "syncing" quá ngưỡng này coi như worker chết — cho xếp hàng lại.
  # Phải LỚN hơn PerformSyncJob::LOCK_TIMEOUT để trễ hàng đợi không bị nhầm.
  SYNC_STALE_TIMEOUT = 2.hours

  DEFAULT_PER_ACCOUNT_BATCH_LIMIT = 50
  DEFAULT_GLOBAL_BATCH_LIMIT = 1000

  def perform(plan_name = nil)
    remaining = global_batch_limit

    candidate_accounts.each do |account|
      next unless account.feature_enabled?('captain_document_auto_sync')

      interval = sync_interval_for(account, plan_name)
      next if interval.blank?

      documents = due_documents(account, interval).limit([per_account_batch_limit, remaining].min).to_a
      documents.each { |document| enqueue_sync(document) }

      remaining -= documents.length
      break if remaining <= 0
    end
  end

  private

  def candidate_accounts
    Account.where(id: Captain::Document.select(:account_id).distinct).order(:id)
  end

  def sync_interval_for(account, plan_name)
    plan = account.custom_attributes&.[]('plan_name').to_s.downcase
    return if plan.blank?
    return if plan_name.present? && plan != plan_name.to_s.downcase

    hours = sync_intervals[plan]
    hours.present? ? hours.to_i.hours : nil
  end

  def sync_intervals
    @sync_intervals ||= begin
      raw = InstallationConfig.find_by(name: 'CAPTAIN_DOCUMENT_AUTO_SYNC_INTERVALS')&.value
      raw.present? ? JSON.parse(raw) : {}
    rescue JSON::ParserError
      {}
    end
  end

  # Đến hạn: chưa từng sync (backfill) / đã sync quá cutoff / lỗi quá cutoff /
  # kẹt "syncing" quá ngưỡng stale. Ưu tiên chưa-từng-thử rồi tới thử lâu nhất.
  def due_documents(account, interval)
    account.captain_documents
           .where(status: :available)
           .syncable
           .where(
             '(sync_status IS NULL) OR ' \
             '(sync_status = :synced AND last_synced_at <= :due_before) OR ' \
             '(sync_status = :failed AND last_sync_attempted_at <= :due_before) OR ' \
             '(sync_status = :syncing AND last_sync_attempted_at <= :stale_before)',
             synced: Captain::Document.sync_statuses[:synced],
             failed: Captain::Document.sync_statuses[:failed],
             syncing: Captain::Document.sync_statuses[:syncing],
             due_before: due_cutoff(interval).ago,
             stale_before: SYNC_STALE_TIMEOUT.ago
           )
           .order(Arel.sql('last_sync_attempted_at ASC NULLS FIRST'))
  end

  def due_cutoff(interval)
    [interval - WEEKLY_SYNC_JITTER, interval / 2].max
  end

  def enqueue_sync(document)
    delay = rand(0..WEEKLY_SYNC_JITTER.to_i)
    Captain::Documents::PerformSyncJob.set(queue: 'purgable', wait: delay.seconds).perform_later(document)
  end

  def per_account_batch_limit
    config_limit('CAPTAIN_DOCUMENT_AUTO_SYNC_PER_ACCOUNT_BATCH_LIMIT', DEFAULT_PER_ACCOUNT_BATCH_LIMIT)
  end

  def global_batch_limit
    config_limit('CAPTAIN_DOCUMENT_AUTO_SYNC_GLOBAL_BATCH_LIMIT', DEFAULT_GLOBAL_BATCH_LIMIT)
  end

  def config_limit(name, default)
    InstallationConfig.find_by(name: name)&.value.presence&.to_i || default
  end
end
