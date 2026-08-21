# frozen_string_literal: true

# Nhật ký kiểm toán ở cấp tài khoản. Hợp đồng phản hồi lấy từ store MIT
# app/javascript/dashboard/store/modules/auditlogs.js: khoá audit_logs,
# current_page, per_page, total_entries — và mặc định per_page = 25.
class Api::V1::Accounts::AuditLogsController < Api::V1::Accounts::BaseController
  RECORDS_PER_PAGE = 25

  before_action :check_admin_authorization?

  def show
    @audit_logs = fetch_audit_logs
  end

  private

  # Tính năng tắt thì trả mảng rỗng chứ không trả lỗi: giao diện vẫn hiển thị
  # trang trống thay vì bung thông báo lỗi.
  def fetch_audit_logs
    return Audited::Audit.none.page(current_page) unless Current.account.feature_enabled?('audit_logs')

    Audited::Audit
      .where(associated_id: Current.account.id, associated_type: 'Account')
      .order(created_at: :desc, id: :desc)
      .page(current_page)
      .per(RECORDS_PER_PAGE)
  end

  def current_page
    params[:page] || 1
  end
end
