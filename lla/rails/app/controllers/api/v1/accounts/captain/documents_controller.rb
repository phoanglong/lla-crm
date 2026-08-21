# frozen_string_literal: true

# Quản lý tài liệu tri thức: liệt kê/xem cho mọi thành viên; nạp mới (kích
# hoạt crawl), sync lại và xoá dành cho administrator.
class Api::V1::Accounts::Captain::DocumentsController < Api::V1::Accounts::Captain::BaseController
  MANUAL_PENDING_STALE_TIMEOUT = 1.hour

  rescue_from ActiveJob::EnqueueError, with: :render_enqueue_failure

  before_action :set_document, only: [:show, :sync, :destroy]
  before_action :check_authorization

  def index
    scope = Current.account.captain_documents.includes(:assistant).ordered
    scope = scope.where(assistant_id: params[:assistant_id]) if params[:assistant_id].present?
    @documents_count = scope.count
    @documents = paginate(scope)
  end

  def show; end

  def create
    @document = Current.account.captain_documents.new(document_params)
    @document.assistant = Current.account.captain_assistants.find(document_params[:assistant_id]) if document_params[:assistant_id].present?
    @document.save!
    enqueue_crawl
    render :show
  end

  # Claim trạng thái pending dưới row lock trước khi enqueue; request lặp lại
  # không sinh thêm job. Chỉ tài liệu web đã crawl xong mới sync được.
  def sync
    return render_could_not_sync(I18n.t('captain.documents.sync_not_supported_for_pdf')) unless @document.syncable?
    return render_could_not_sync(I18n.t('captain.documents.sync_only_available_documents')) unless @document.available?
    return head :accepted unless claim_sync

    enqueue_sync
    head :accepted
  end

  def destroy
    @document.destroy!
    head :no_content
  end

  private

  def set_document
    @document = Current.account.captain_documents.find(params[:id])
  end

  def check_authorization
    authorize(@document || Captain::Document)
  end

  def document_params
    params.require(:document).permit(:name, :external_link, :assistant_id, :pdf_file)
  end

  def render_could_not_sync(message)
    render json: { error: message }, status: :unprocessable_entity
  end

  def render_enqueue_failure
    render json: { error: 'Knowledge processing queue is temporarily unavailable' }, status: :service_unavailable
  end

  def sync_already_queued?
    return true if @document.sync_in_progress?

    @document.sync_pending? && @document.last_sync_attempted_at.present? &&
      @document.last_sync_attempted_at > MANUAL_PENDING_STALE_TIMEOUT.ago
  end

  def claim_sync
    claimed = false
    @document.with_lock do
      next if sync_already_queued?

      @document.update!(sync_status: :pending, last_sync_error_code: nil, last_sync_attempted_at: Time.current)
      @sync_claimed_at = @document.last_sync_attempted_at
      claimed = true
    end
    claimed
  end

  def enqueue_sync
    ensure_enqueued!(Captain::Documents::PerformSyncJob.perform_later(@document))
  rescue StandardError
    mark_enqueue_failed
    raise
  end

  def enqueue_crawl
    ensure_enqueued!(Captain::Documents::CrawlJob.perform_later(@document))
  rescue StandardError
    metadata = @document.metadata.to_h.merge('ingestion_error_code' => 'enqueue_failed')
    @document.update!(status: :failed, metadata: metadata)
    raise
  end

  def ensure_enqueued!(job)
    raise ActiveJob::EnqueueError, 'Job enqueue was rejected' unless job
    raise job.enqueue_error if job.respond_to?(:enqueue_error) && job.enqueue_error

    job
  end

  def mark_enqueue_failed
    @document.with_lock do
      next unless @document.sync_pending? && @document.last_sync_attempted_at == @sync_claimed_at

      @document.update!(sync_status: :failed, last_sync_error_code: 'enqueue_failed', last_sync_attempted_at: nil)
    end
  end
end
