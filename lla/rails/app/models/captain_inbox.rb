# frozen_string_literal: true

# Nối trợ lý AI với một inbox — inbox nào bật trợ lý nào.
class CaptainInbox < ApplicationRecord
  self.table_name = 'captain_inboxes'

  belongs_to :captain_assistant, class_name: 'Captain::Assistant'
  belongs_to :inbox

  validates :inbox_id, uniqueness: { scope: :captain_assistant_id }
  validate :assistant_and_inbox_belong_to_same_account

  private

  def assistant_and_inbox_belong_to_same_account
    return if captain_assistant.blank? || inbox.blank?
    return if captain_assistant.account_id == inbox.account_id

    errors.add(:inbox, 'must belong to the same account as the assistant')
  end
end
