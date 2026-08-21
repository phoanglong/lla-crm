# frozen_string_literal: true

# Công ty (tài khoản khách hàng B2B) — gom contact theo domain email.
#
# Hợp đồng lấy từ nguồn MIT: db/schema.rb (bảng companies, cột
# contacts.company_id + contacts_count counter cache),
# spec/enterprise/models/company_spec.rb (đã chuyển sang spec/lla) và
# app/javascript/dashboard/api/companies.js.
class Company < ApplicationRecord
  include Avatarable

  DOMAIN_FORMAT = /\A[a-z0-9]+([\-.][a-z0-9]+)*\.[a-z]{2,}\z/i

  belongs_to :account
  has_many :contacts, dependent: :nullify

  validates :account_id, presence: true
  validates :name, presence: true, length: { maximum: 100 }
  validates :description, length: { maximum: 1000 }
  validates :domain, format: { with: DOMAIN_FORMAT }, allow_blank: true

  scope :ordered_by_name, -> { order(:name) }

  after_update_commit :sync_contact_names, if: :saved_change_to_name?

  # Hoạt động của công ty = hoạt động mới nhất của contact — không bao giờ lùi.
  def record_activity_at!(timestamp)
    return if timestamp.blank?
    return if last_activity_at.present? && last_activity_at >= timestamp

    update!(last_activity_at: timestamp)
  end

  private

  def sync_contact_names
    Companies::SyncContactNamesJob.perform_later(company_id: id)
  end
end
