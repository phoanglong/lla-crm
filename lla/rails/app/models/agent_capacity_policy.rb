# frozen_string_literal: true

# Chính sách tải của agent: mỗi agent (qua account_users.agent_capacity_policy_id)
# chịu giới hạn số hội thoại open theo từng inbox (inbox_capacity_limits).
#
# Hợp đồng lấy từ nguồn MIT: db/schema.rb (bảng agent_capacity_policies,
# cột account_users.agent_capacity_policy_id), spec/enterprise/models/** và
# app/javascript/dashboard/api/agentCapacityPolicies.js.
class AgentCapacityPolicy < ApplicationRecord
  belongs_to :account

  has_many :inbox_capacity_limits, dependent: :destroy
  # Xoá chính sách không được xoá thành viên — chỉ gỡ liên kết.
  has_many :account_users, dependent: :nullify
  has_many :users, through: :account_users

  validates :name, presence: true, length: { maximum: 255 }
end
