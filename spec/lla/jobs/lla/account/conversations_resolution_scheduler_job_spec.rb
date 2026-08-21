# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Account::ConversationsResolutionSchedulerJob, type: :job do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let!(:captain_inbox) { create(:captain_inbox, captain_assistant: assistant, inbox: inbox) }
  let(:window) { Time.zone.parse('2026-08-16 04:00:00').to_i }

  after do
    Redis::Alfred.delete(schedule_key(account, inbox))
  end

  it 'claims each account and inbox once per scheduling window' do
    job = described_class.new

    expect do
      2.times { job.send(:schedule_captain_inboxes, window) }
    end.to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob).with(inbox).exactly(:once)
  end

  it 'releases a failed claim and continues scheduling other inboxes' do
    second_inbox = create(:inbox, account: account)
    create(:captain_inbox, captain_assistant: assistant, inbox: second_inbox)
    allow(Captain::InboxPendingConversationsResolutionJob).to receive(:perform_later) do |scheduled_inbox|
      raise ActiveJob::EnqueueError, 'queue unavailable' if scheduled_inbox.id == inbox.id
    end

    described_class.new.send(:schedule_captain_inboxes, window)

    expect(Captain::InboxPendingConversationsResolutionJob).to have_received(:perform_later).with(second_inbox)
    expect(Redis::Alfred.get(schedule_key(account, inbox))).to be_nil
  ensure
    Redis::Alfred.delete(schedule_key(account, second_inbox)) if second_inbox
  end

  it 'rejects a stale cross-account Captain inbox association' do
    other_assistant = create(:captain_assistant, account: create(:account))
    captain_inbox.update_column(:captain_assistant_id, other_assistant.id) # rubocop:disable Rails/SkipsModelValidations

    expect do
      described_class.new.send(:schedule_captain_inboxes, window)
    end.not_to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob).with(inbox)
  end

  it 'does not schedule work for a suspended account' do
    account.suspended!

    expect do
      described_class.new.send(:schedule_captain_inboxes, window)
    end.not_to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob).with(inbox)
  end

  def schedule_key(target_account, target_inbox)
    format(
      Lla::Account::ConversationsResolutionSchedulerJob::SCHEDULE_KEY,
      account_id: target_account.id,
      inbox_id: target_inbox.id,
      window: window
    )
  end
end
