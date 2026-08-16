# frozen_string_literal: true

class CopilotThread < ApplicationRecord
  TITLE_LENGTH_LIMIT = 160
  HISTORY_MESSAGE_LIMIT = 40
  HISTORY_ITEM_BYTES = 8_192
  HISTORY_TOTAL_BYTES = 65_536

  belongs_to :user
  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant'
  has_many :copilot_messages, dependent: :destroy_async, inverse_of: :copilot_thread

  validates :title, presence: true, length: { maximum: TITLE_LENGTH_LIMIT }
  validate :user_belongs_to_account

  before_validation :ensure_account

  def push_event_data
    {
      id: id,
      title: title,
      created_at: created_at.to_i,
      user: user.push_event_data,
      account_id: account_id
    }
  end

  def previous_history
    remaining_bytes = HISTORY_TOTAL_BYTES

    copilot_messages
      .where(message_type: %w[user assistant])
      .order(created_at: :desc, id: :desc)
      .limit(HISTORY_MESSAGE_LIMIT)
      .reverse_each
      .filter_map do |copilot_message|
        content = copilot_message.message['content']
        next unless content.is_a?(String) && content.present? && remaining_bytes.positive?

        bounded_content = content.byteslice(0, [HISTORY_ITEM_BYTES, remaining_bytes].min).to_s.scrub
        remaining_bytes -= bounded_content.bytesize
        { content: bounded_content, role: copilot_message.message_type }
      end
  end

  private

  def ensure_account
    self.account_id = assistant&.account_id
  end

  def user_belongs_to_account
    return if account_id.blank? || user_id.blank?
    return if AccountUser.exists?(account_id: account_id, user_id: user_id)

    errors.add(:user, 'must belong to the thread account')
  end
end
