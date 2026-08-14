# frozen_string_literal: true

# Lớp bản ghi kiểm toán của LLA. Kế thừa Audited::Audit nên dùng chung bảng
# `audits` trong db/schema.rb (MIT) — không thêm migration, không đổi dữ liệu cũ.
class Lla::AuditLog < Audited::Audit
end
