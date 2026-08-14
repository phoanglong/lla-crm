# frozen_string_literal: true

# User KHÔNG sinh bản ghi kiểm toán tự động: thao tác trên hồ sơ người dùng có
# thể thuộc nhiều tài khoản nên không gắn được associated_id duy nhất, và mỗi lần
# đăng nhập Devise ghi lại tokens/sign_in_count sẽ tạo rác trong nhật ký.
#
# Ở đây chỉ khai báo quan hệ `user.audits` để các sự kiện ghi tay
# (sign_in / sign_out trong Lla::DeviseOverrides::SessionsController) truy vấn được.
# Không dùng macro `audited on: []` — gem audited coi mảng rỗng là "không truyền"
# và quay về mặc định [:create, :update, :touch, :destroy].
module Lla::Audit::User
  extend ActiveSupport::Concern

  included do
    has_many :audits, -> { order(id: :asc) },
             as: :auditable,
             class_name: 'Audited::Audit',
             inverse_of: :auditable,
             dependent: :destroy
  end
end
