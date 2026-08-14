# frozen_string_literal: true

# Ghi vết kiểm toán cho Macro — năng lực do LLA phát triển (Wave B2).
#
# Danh mục hành động lấy từ hợp đồng giao diện MIT:
# app/javascript/dashboard/helper/auditlogHelper.js — bảng translationKeys.
# Bảng `audits` nằm trong db/schema.rb (MIT); gem `audited` đã có sẵn trong Gemfile.
module Lla::Audit::Macro
  extend ActiveSupport::Concern

  included do
    audited associated_with: :audited_account, on: %i[create update destroy]
  end

  def audited_account
    account
  end
end
