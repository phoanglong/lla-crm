# frozen_string_literal: true

# Một lần lỡ hạn SLA (frt/nrt/rt) trên một hội thoại. Tạo bản ghi là phát luôn
# thông báo cho assignee, người tham gia và administrator của tài khoản.
class SlaEvent < ApplicationRecord
  belongs_to :applied_sla
  belongs_to :conversation
  belongs_to :account
  belongs_to :sla_policy
  belongs_to :inbox

  enum event_type: { frt: 0, nrt: 1, rt: 2 }

  NOTIFICATION_TYPES = {
    'frt' => 'sla_missed_first_response',
    'nrt' => 'sla_missed_next_response',
    'rt' => 'sla_missed_resolution'
  }.freeze

  before_validation :backfill_ids
  after_create_commit :notify_watchers

  def push_event_data
    {
      id: id,
      event_type: event_type,
      meta: meta,
      created_at: created_at.to_i,
      updated_at: updated_at.to_i
    }
  end

  private

  def backfill_ids
    self.account_id ||= conversation&.account_id
    self.inbox_id ||= conversation&.inbox_id
    self.sla_policy_id ||= applied_sla&.sla_policy_id
  end

  def notify_watchers
    watchers = (account.administrators.to_a + [conversation.assignee] + conversation.conversation_participants.map(&:user)).compact.uniq

    watchers.each do |user|
      NotificationBuilder.new(
        notification_type: NOTIFICATION_TYPES.fetch(event_type),
        user: user,
        account: account,
        primary_actor: conversation,
        secondary_actor: sla_policy
      ).perform
    end
  end
end
