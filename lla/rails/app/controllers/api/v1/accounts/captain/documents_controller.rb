# frozen_string_literal: true

# Quản lý tài liệu tri thức: liệt kê/xem cho mọi thành viên; nạp mới (kích
# hoạt crawl), sync lại và xoá dành cho administrator.
class Api::V1::Accounts::Captain::DocumentsController < Api::V1::Accounts::Captain::BaseController
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
    Captain::Documents::CrawlJob.perform_later(@document)
    render :show
  end

  # Cho phép sync lại cả khi đang "syncing" (kẹt hay không) — PerformSyncJob tự
  # chống chồng bằng khoá Redis; chỉ chặn PDF và tài liệu chưa crawl xong.
  def sync
    return render_could_not_sync(I18n.t('captain.documents.sync_not_supported_for_pdf')) unless @document.syncable?
    return render_could_not_sync(I18n.t('captain.documents.sync_only_available_documents')) unless @document.available?

    @document.update!(sync_status: :syncing, last_sync_attempted_at: Time.current)
    Captain::Documents::PerformSyncJob.perform_later(@document)
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
end
