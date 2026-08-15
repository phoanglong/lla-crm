# frozen_string_literal: true

# Tài liệu tri thức của trợ lý: trang web (crawl) hoặc PDF đính kèm. Khi tài liệu
# sẵn sàng và có nội dung, sinh FAQ qua ResponseBuilderJob.
class Captain::Document < ApplicationRecord
  self.table_name = 'captain_documents'

  MAX_PDF_SIZE = 10.megabytes

  # Quá ngưỡng này mà vẫn "syncing" thì coi là kẹt — cho phép sync lại.
  SYNC_STALE_TIMEOUT = 1.hour

  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :account

  has_many :responses, class_name: 'Captain::AssistantResponse', as: :documentable, dependent: :destroy_async
  has_one_attached :pdf_file

  # Trạng thái chi tiết của lần sync gần nhất + dấu vân nội dung (phát hiện nội
  # dung đổi giữa hai lần sync) — lưu trong metadata, không cần cột riêng.
  store_accessor :metadata, :sync_step, :last_sync_error_code, :content_fingerprint

  enum status: { in_progress: 0, available: 1, failed: 2 }
  enum sync_status: { pending: 0, syncing: 1, synced: 2, failed: 3 }, _prefix: :sync

  validates :external_link, presence: true, unless: :pdf_file_attached?
  validates :external_link, uniqueness: { scope: :assistant_id }, allow_blank: true
  validate :validate_pdf_file
  validate :validate_document_limit, on: :create

  scope :ordered, -> { order(created_at: :desc) }
  # Chỉ tài liệu web mới sync lại được — PDF (link dạng PDF hoặc có file đính
  # kèm) không có nguồn để crawl.
  scope :syncable, lambda {
    where.not("external_link LIKE 'PDF:%' OR external_link LIKE '%.pdf'").where.missing(:pdf_file_attachment)
  }

  before_validation :normalize_external_link
  before_validation :assign_pdf_external_link
  before_validation :assign_account_from_assistant

  after_commit :enqueue_response_builder, on: [:create, :update]
  after_commit :update_account_document_usage, on: [:create, :destroy]

  # MIME/kích thước file PDF đính kèm (nil với tài liệu web) — payload API.
  def content_type
    pdf_file.attached? ? pdf_file.content_type : nil
  end

  def file_size
    pdf_file.attached? ? pdf_file.byte_size : nil
  end

  # Ngữ cảnh nhận diện tài liệu cho instrumentation/LLM.
  def to_llm_metadata
    {
      document_id: id,
      account_id: account_id,
      assistant_id: assistant_id,
      external_link: external_link
    }
  end

  def pdf_document?
    return true if pdf_file.attached?
    return false if external_link.blank?

    external_link.start_with?('PDF:') || external_link.end_with?('.pdf')
  end

  # PDF không sync lại được — chỉ tài liệu web có nguồn để crawl.
  def syncable?
    !pdf_document?
  end

  # Đang sync thật sự: trạng thái syncing VÀ lần thử gần nhất chưa quá ngưỡng
  # kẹt — quá ngưỡng thì coi như không còn chạy, cho phép sync lại.
  def sync_in_progress?
    sync_syncing? && last_sync_attempted_at.present? && last_sync_attempted_at > SYNC_STALE_TIMEOUT.ago
  end

  def display_url
    return external_link unless pdf_file.attached?

    Rails.application.routes.url_helpers.rails_blob_url(pdf_file)
  end

  def openai_file_id
    metadata&.dig('openai_file_id')
  end

  def store_openai_file_id(file_id)
    update!(metadata: (metadata || {}).merge('openai_file_id' => file_id))
  end

  private

  def pdf_file_attached?
    pdf_file.attached?
  end

  # Account luôn theo assistant — tạo qua assistant.documents không cần truyền
  # account, và chặn lệch account giữa tài liệu và trợ lý.
  def assign_account_from_assistant
    self.account = assistant.account if assistant.present?
  end

  def normalize_external_link
    self.external_link = external_link.delete_suffix('/') if external_link.present?
  end

  # PDF không có URL nguồn — sinh định danh duy nhất từ tên file để giữ ràng buộc
  # unique(assistant, external_link).
  def assign_pdf_external_link
    return if external_link.present?
    return unless pdf_file.attached?

    base_name = File.basename(pdf_file.filename.to_s, '.*').parameterize(separator: '_')
    self.external_link = "PDF: #{base_name}_#{Time.current.strftime('%Y%m%d%H%M%S')}"
  end

  def validate_pdf_file
    return unless pdf_file.attached?
    return if pdf_file.byte_size <= MAX_PDF_SIZE

    errors.add(:pdf_file, I18n.t('captain.documents.pdf_size_error'))
  end

  # Hạn mức tài liệu theo gói (chỉ khi lớp quota có mặt và cấu hình giới hạn).
  def validate_document_limit
    return if account.blank? || !account.respond_to?(:usage_limits)

    remaining = account.usage_limits.dig(:captain, :documents, :current_available)
    return if remaining.nil? || remaining.positive?

    errors.add(:base, I18n.t('captain.documents.limit_exceeded'))
  end

  # Web: cần status available VÀ có nội dung; chạy khi vừa chuyển available hoặc
  # nội dung vừa đổi. PDF: nội dung trích sau nên chỉ chạy theo nhịp chuyển
  # available (kể cả lúc tạo), không chạy lại khi content đổ về.
  def enqueue_response_builder
    return unless available?

    Captain::Documents::ResponseBuilderJob.perform_later(self) if pdf_document? ? pdf_build_due? : web_build_due?
  end

  def pdf_build_due?
    saved_change_to_status? || just_created?
  end

  def web_build_due?
    content.present? && (saved_change_to_status? || saved_change_to_content? || just_created?)
  end

  def just_created?
    saved_change_to_id?
  end

  # Đồng bộ chỉ số dùng tài liệu cho hạn mức gói (chỉ có ở lớp quota — EE hiện
  # tại, sang wave E5 là lla). Không có lớp quota thì bỏ qua.
  def update_account_document_usage
    account.update_document_usage if account.respond_to?(:update_document_usage)
  end
end
