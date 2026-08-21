# frozen_string_literal: true

# Giới hạn hội thoại open cho một inbox trong một chính sách tải.
# `conversation_limit = 0` là chính sách loại trừ: agent thuộc chính sách này
# không bao giờ được auto-assign ở inbox đó.
class InboxCapacityLimit < ApplicationRecord
  belongs_to :agent_capacity_policy
  belongs_to :inbox

  validates :conversation_limit, presence: true,
                                 numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :inbox_id, uniqueness: { scope: :agent_capacity_policy_id }
end
