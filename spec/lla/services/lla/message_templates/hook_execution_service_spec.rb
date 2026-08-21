# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplates::HookExecutionService, type: :service do
  let(:account) { create(:account, limits: { captain_responses: 10 }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:assistant) { create(:captain_assistant, account: account) }

  before do
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
  end

  after do
    Redis::Alfred.delete(schedule_key)
  end

  it 'coalesces a burst of incoming messages into one response job' do
    allow(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later)

    create(:message, conversation: conversation, account: account, message_type: :incoming)
    create(:message, conversation: conversation, account: account, message_type: :incoming)

    expect(Captain::Conversation::ResponseBuilderJob).to have_received(:perform_later).once
  end

  it 'releases only its own scheduling token when enqueue fails' do
    allow(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, 'unavailable')

    expect do
      create(:message, conversation: conversation, account: account, message_type: :incoming)
    end.to raise_error(ActiveJob::EnqueueError, 'unavailable')

    expect(Redis::Alfred.get(schedule_key)).to be_nil
  end

  it 'does not schedule through an inconsistent cross-account assistant' do
    message = create(:message, conversation: conversation, account: account, message_type: :incoming)
    Redis::Alfred.delete(schedule_key)
    foreign_assistant = create(:captain_assistant)
    allow(message).to receive(:inbox).and_return(inbox)
    allow(inbox).to receive(:captain_assistant).and_return(foreign_assistant)
    allow(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later)

    described_class.new(message: message).perform

    expect(Captain::Conversation::ResponseBuilderJob).not_to have_received(:perform_later)
  end

  it 'performs a quota handoff only once' do
    CaptainInbox.where(inbox: inbox).delete_all
    message = create(:message, conversation: conversation, account: account, message_type: :incoming)
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    service = described_class.new(message: message)

    service.send(:perform_handoff)
    service.send(:perform_handoff)

    transfers = conversation.messages.outgoing.where(content: 'Transferring to another agent for further assistance.')
    expect(transfers.count).to eq(1)
    expect(conversation.reload).to be_open
  end

  private

  def schedule_key
    Lla::Captain::ResponseCoordination.schedule_key(
      account_id: account.id,
      conversation_id: conversation.id
    )
  end
end
