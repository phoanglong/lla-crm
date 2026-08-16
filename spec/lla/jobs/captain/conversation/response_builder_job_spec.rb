# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Conversation::ResponseBuilderJob, type: :job do
  include ActiveJob::TestHelper

  let(:account) { create(:account, limits: { captain_responses: 10 }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let!(:incoming_message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Hello')
  end
  let(:chat_service) { instance_double(Captain::Llm::AssistantChatService) }

  before do
    clear_enqueued_jobs
    allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(chat_service)
    allow(chat_service).to receive(:generate_response).and_return('response' => 'LLA reply')
  end

  after do
    Redis::Alfred.delete(schedule_key)
    Redis::Alfred.delete(execution_key)
  end

  it 'delivers and accounts for a trigger at most once across retries' do
    2.times { described_class.perform_now(conversation, assistant) }

    replies = conversation.messages.outgoing.where(sender_type: 'Captain::Assistant')
    expect(replies.count).to eq(1)
    expect(replies.first.additional_attributes['captain_source_message_id']).to eq(incoming_message.id)
    expect(account.reload.custom_attributes['captain_responses_usage']).to eq(1)
    expect(chat_service).to have_received(:generate_response).once
  end

  it 'does not execute when another worker owns the conversation lock' do
    Redis::Alfred.set(execution_key, 'other-worker', ex: 1.minute.to_i)

    described_class.perform_now(conversation, assistant)

    expect(chat_service).not_to have_received(:generate_response)
    expect(Redis::Alfred.get(execution_key)).to eq('other-worker')
  end

  it 'rejects a cross-account assistant before invoking the model' do
    described_class.perform_now(conversation, create(:captain_assistant))

    expect(chat_service).not_to have_received(:generate_response)
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not post over a human reply created while the model is running' do
    agent = create(:user, account: account)
    allow(chat_service).to receive(:generate_response) do
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :outgoing,
        sender: agent,
        content: 'Human reply'
      )
      { 'response' => 'Stale bot reply' }
    end

    described_class.perform_now(conversation, assistant)

    expect(conversation.messages.outgoing.where(sender_type: 'Captain::Assistant')).to be_empty
  end

  it 'drops a stale draft and schedules the latest incoming message' do
    allow(chat_service).to receive(:generate_response) do
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'New detail'
      )
      { 'response' => 'Stale bot reply' }
    end

    expect do
      described_class.perform_now(conversation, assistant)
    end.to have_enqueued_job(described_class).with(conversation, assistant).once

    expect(conversation.messages.outgoing.where(sender_type: 'Captain::Assistant')).to be_empty
  end

  it 'hands off atomically when the final quota unit was already consumed' do
    account.update!(limits: { captain_responses: 0 })

    described_class.perform_now(conversation, assistant)

    expect(conversation.reload).to be_open
    expect(conversation.messages.outgoing.last.content).to eq(I18n.t('conversations.captain.handoff'))
    expect(account.reload.custom_attributes['captain_responses_usage']).to be_nil
  end

  it 'removes a malformed scheduling token without invoking the model' do
    Redis::Alfred.set(schedule_key, 'malformed', ex: 1.minute.to_i)

    described_class.perform_now(conversation, assistant)

    expect(chat_service).not_to have_received(:generate_response)
    expect(Redis::Alfred.get(schedule_key)).to be_nil
  end

  unless ChatwootApp.enterprise?
    it 'fails closed to human handoff when V2 is enabled but a required runtime constant is unavailable' do
      account.enable_features!('captain_integration_v2')
      hide_const('Captain::Assistant::SessionCaptureService')

      described_class.perform_now(conversation, assistant)

      expect(chat_service).not_to have_received(:generate_response)
      expect(conversation.reload).to be_open
      expect(conversation.messages.outgoing.last.content).to eq(I18n.t('conversations.captain.handoff'))
    end
  end

  private

  def schedule_key
    Lla::Captain::ResponseCoordination.schedule_key(account_id: account.id, conversation_id: conversation.id)
  end

  def execution_key
    Lla::Captain::ResponseCoordination.execution_key(account_id: account.id, conversation_id: conversation.id)
  end
end
