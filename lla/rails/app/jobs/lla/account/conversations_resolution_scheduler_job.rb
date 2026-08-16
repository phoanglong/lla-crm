# frozen_string_literal: true

require 'securerandom'

# Adds Captain inbox resolution scheduling after the CE account-resolution pass.
# A per-inbox/time-window Redis claim prevents overlapping schedulers from
# enqueueing duplicate effective work.
module Lla::Account::ConversationsResolutionSchedulerJob
  CLAIM_TTL = 70.minutes.to_i
  SCHEDULE_KEY = 'LLA_CAPTAIN_RESOLUTION_SCHEDULE::%<account_id>d::%<inbox_id>d::%<window>d'

  def perform
    super
    schedule_captain_inboxes(Time.current.beginning_of_hour.to_i)
  end

  private

  def schedule_captain_inboxes(window)
    CaptainInbox.includes(:captain_assistant, inbox: [:account, :channel]).find_each(batch_size: 100) do |captain_inbox|
      schedule_captain_inbox(captain_inbox, window)
    rescue StandardError => e
      account = captain_inbox&.inbox&.account
      ChatwootExceptionTracker.new(e, account: account).capture_exception
      Rails.logger.warn(
        "LLA Captain resolution schedule failed captain_inbox_id=#{captain_inbox&.id} error=#{e.class.name}"
      )
    end
  end

  def schedule_captain_inbox(captain_inbox, window)
    inbox = captain_inbox.inbox
    assistant = captain_inbox.captain_assistant
    return unless schedulable_context?(inbox, assistant)

    key = format(SCHEDULE_KEY, account_id: inbox.account_id, inbox_id: inbox.id, window: window)
    token = SecureRandom.hex(16)
    return unless Redis::Alfred.set(key, token, nx: true, ex: CLAIM_TTL)

    Captain::InboxPendingConversationsResolutionJob.perform_later(inbox)
  rescue StandardError
    Redis::Alfred.delete_if_equals(key, token) if key && token
    raise
  end

  def schedulable_context?(inbox, assistant)
    return false if inbox.blank? || assistant.blank? || inbox.email?
    return false unless inbox.account&.active?
    return false if inbox.account.captain_auto_resolve_disabled?

    assistant.account_id == inbox.account_id
  end
end
