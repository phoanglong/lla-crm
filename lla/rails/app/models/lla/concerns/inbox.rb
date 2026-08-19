# frozen_string_literal: true

# Captain associations required by the LLA-owned auto-reply runtime, the capacity
# limits the assignment services read, and the account inbox limit.
module Lla::Concerns::Inbox
  extend ActiveSupport::Concern

  included do
    has_one :captain_inbox, dependent: :destroy, class_name: 'CaptainInbox'
    has_one :captain_assistant,
            through: :captain_inbox,
            class_name: 'Captain::Assistant'
    has_many :calls, dependent: :destroy_async

    # `inbox_capacity_limits` has no database foreign key — the migration that
    # created it used a plain `t.references`. Without this association, destroying
    # an inbox leaves rows behind that `Lla::AutoAssignment::CapacityService` then
    # reads, so a deleted inbox keeps capping a live agent.
    has_many :inbox_capacity_limits, dependent: :destroy

    before_create :ensure_create_permitted
  end

  # Raises rather than silently exceeding the account's inbox allowance. The
  # controllers that create inboxes already rescue this exception; the check that
  # produced it lived in an enterprise concern.
  def ensure_create_permitted
    limit = account.usage_limits[:inboxes]
    return if limit.blank?
    return if account.inboxes.count < limit

    raise CustomExceptions::Inbox::LimitExceeded.new(limit: limit)
  end
end
