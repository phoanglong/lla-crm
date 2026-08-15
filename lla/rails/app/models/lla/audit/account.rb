# frozen_string_literal: true

# Ghi vết kiểm toán cho Account — năng lực do LLA phát triển (Wave B2).
#
# Danh mục hành động lấy từ hợp đồng giao diện MIT:
# app/javascript/dashboard/helper/auditlogHelper.js — bảng translationKeys.
# Bảng `audits` nằm trong db/schema.rb (MIT); gem `audited` đã có sẵn trong Gemfile.
module Lla::Audit::Account
  extend ActiveSupport::Concern

  included do
    audited associated_with: :audited_account, on: %i[update]
    # Cho phép đọc mọi bản ghi kiểm toán gắn associated về account
    # (account.associated_audits — gem audited).
    has_associated_audits
  end

  # Account là gốc của chính nó: bản ghi kiểm toán vẫn phải gắn associated_id
  # về account để API /audit_logs gom được cùng một chỗ.
  def audited_account
    self
  end
end
