# frozen_string_literal: true

# Nối trợ lý AI với một inbox — inbox nào bật trợ lý nào.
class CaptainInbox < ApplicationRecord
  self.table_name = 'captain_inboxes'

  belongs_to :captain_assistant, class_name: 'Captain::Assistant'
  belongs_to :inbox

  validates :inbox_id, uniqueness: { scope: :captain_assistant_id }
end
