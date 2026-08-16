# frozen_string_literal: true

# Captain associations required by the LLA-owned auto-reply runtime. Capacity,
# calls and plan-specific inbox limits remain in their own waves.
module Lla::Concerns::Inbox
  extend ActiveSupport::Concern

  included do
    has_one :captain_inbox, dependent: :destroy, class_name: 'CaptainInbox'
    has_one :captain_assistant,
            through: :captain_inbox,
            class_name: 'Captain::Assistant'
    has_many :calls, dependent: :destroy_async
  end
end
