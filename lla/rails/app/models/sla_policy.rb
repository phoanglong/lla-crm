# frozen_string_literal: true

# Chính sách SLA của tài khoản: ngưỡng thời gian phản hồi đầu (frt), phản hồi
# kế tiếp (nrt) và giải quyết (rt), tuỳ chọn chỉ tính trong giờ làm việc.
#
# Hợp đồng lấy từ nguồn MIT: db/schema.rb (bảng sla_policies, cột
# conversations.sla_policy_id) và spec/enterprise/models/sla_policy_spec.rb
# (đã chuyển sang spec/lla).
class SlaPolicy < ApplicationRecord
  belongs_to :account

  has_many :conversations, dependent: :nullify
  has_many :applied_slas, dependent: :destroy_async

  validates :name, presence: true

  # Notification#push_event_data phát secondary_actor (chính là SlaPolicy) qua
  # websocket khi báo lỡ hạn SLA.
  def push_event_data
    {
      id: id,
      name: name,
      description: description,
      first_response_time_threshold: first_response_time_threshold,
      next_response_time_threshold: next_response_time_threshold,
      resolution_time_threshold: resolution_time_threshold,
      only_during_business_hours: only_during_business_hours,
      created_at: created_at.to_i,
      updated_at: updated_at.to_i
    }
  end
end
