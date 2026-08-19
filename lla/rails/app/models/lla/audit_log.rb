# frozen_string_literal: true

# Lớp bản ghi kiểm toán của LLA. Kế thừa Audited::Audit nên dùng chung bảng
# `audits` trong db/schema.rb (MIT) — không thêm migration, không đổi dữ liệu cũ.
class Lla::AuditLog < Audited::Audit
  # An audit row whose actor is recorded only as a numeric id answers "what
  # changed" but not "who changed it" once that user is deleted. The email is
  # stamped at write time so the record survives the account it names.
  after_save :stamp_actor_username

  private

  def stamp_actor_username
    return if user.blank?
    return if username.present?

    update_column(:username, user.try(:email)) # rubocop:disable Rails/SkipsModelValidations
  end
end
