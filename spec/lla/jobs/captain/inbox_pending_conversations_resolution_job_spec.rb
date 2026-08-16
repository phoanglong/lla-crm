# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::InboxPendingConversationsResolutionJob, type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:captain_inbox) { create(:captain_inbox, inbox: inbox, captain_assistant: assistant) }

  before { captain_inbox }

  it 'reloads a valid same-account Captain runtime context' do
    job = described_class.new

    job.send(:assign_runtime_context, inbox)

    expect(job.send(:valid_runtime_context?)).to be true
  end

  it 'selects an inactive pending conversation using one cutoff snapshot' do
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending, last_activity_at: 2.hours.ago)
    job = described_class.new
    job.send(:assign_runtime_context, inbox)
    job.instance_variable_set(:@cutoff, 1.hour.ago)

    expect(job.send(:resolvable_pending_conversations)).to include(conversation)
  end

  it 'applies a legacy resolution atomically for the same activity revision' do
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending, last_activity_at: 2.hours.ago)
    job = described_class.new
    job.send(:assign_runtime_context, inbox)
    job.instance_variable_set(:@cutoff, 1.hour.ago)

    job.send(:apply_time_based_resolution, conversation, conversation.last_activity_at)

    expect(conversation.reload).to be_resolved
  end

  it 'runs the legacy path through the public job entry point' do
    stub_const('Limits::BULK_ACTIONS_LIMIT', 3)
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending, last_activity_at: 2.hours.ago)
    create(:conversation, account: account, inbox: inbox, status: :pending, last_activity_at: 1.minute.ago)
    create(:conversation, account: account, inbox: inbox, status: :open, last_activity_at: 1.hour.ago)

    described_class.perform_now(inbox)

    expect(conversation.reload).to be_resolved
  end

  it 'rejects a pending conversation whose account does not own the inbox' do
    malformed = create(
      :conversation,
      account: create(:account),
      inbox: inbox,
      status: :pending,
      last_activity_at: 2.hours.ago
    )
    allow(Captain::ConversationCompletionService).to receive(:new)

    described_class.perform_now(inbox)

    expect(malformed.reload).to be_pending
    expect(Captain::ConversationCompletionService).not_to have_received(:new)
  end

  it 'does not duplicate effective legacy resolution work' do
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending, last_activity_at: 2.hours.ago)

    2.times { described_class.perform_now(inbox) }

    expect(conversation.reload).to be_resolved
    expect(conversation.messages.where("additional_attributes ? 'lla_captain_resolution'").count).to eq(1)
  end

  it 'clamps a configured inactivity interval to the supported range' do
    job = described_class.new

    # Simulate legacy/corrupt settings that predate the current model validation.
    account.update_column(:settings, account.settings.merge('auto_resolve_after' => 1)) # rubocop:disable Rails/SkipsModelValidations
    job.send(:assign_runtime_context, inbox)
    expect(job.send(:inactivity_minutes)).to eq(described_class::MIN_INACTIVITY_MINUTES)

    account.update_column(:settings, account.settings.merge('auto_resolve_after' => 20_000)) # rubocop:disable Rails/SkipsModelValidations
    job.send(:assign_runtime_context, inbox)
    expect(job.send(:inactivity_minutes)).to eq(described_class::MAX_INACTIVITY_MINUTES)
  end

  it 'clears request-local execution context when runtime loading fails' do
    Current.executed_by = assistant
    allow(Inbox).to receive(:includes).and_raise(ActiveRecord::ConnectionNotEstablished, 'database unavailable')

    expect { described_class.new.perform(inbox) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    expect(Current.executed_by).to be_nil
  end
end
