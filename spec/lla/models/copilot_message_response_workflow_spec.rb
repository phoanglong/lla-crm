# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CopilotMessage, type: :model do
  let(:account) { create(:account, limits: { captain_responses: 2 }) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }

  def create_source(content = 'Private prompt')
    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: :user,
      message: { 'content' => content }
    )
  end

  describe 'reservation accounting' do
    it 'reserves quota once across stale model instances' do
      source = create_source
      stale_copy = described_class.find(source.id)

      expect(source.reserve_response!).to be true
      expect(stale_copy.reserve_response!).to be true

      expect(source.reload).to be_response_reserved
      expect(source.response_job_token).to match(described_class::RESPONSE_TOKEN_FORMAT)
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(1)
    end

    it 'releases quota exactly once across duplicate cleanup paths' do
      source = create_source
      source.reserve_response!
      stale_copy = described_class.find(source.id)

      expect(source.release_response!).to be true
      expect(stale_copy.release_response!).to be false

      expect(source.reload).to be_response_released
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(0)
    end

    it 'fails closed after the last configured response is reserved' do
      account.update!(limits: { captain_responses: 1 })
      first = create_source('first')
      second = create_source('second')

      expect(first.reserve_response!).to be true
      expect(second.reserve_response!).to be false

      expect(first.reload).to be_response_reserved
      expect(second.reload).to be_response_none
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(1)
    end

    it 'releases quota and stores one generic response when enqueueing fails' do
      source = create_source
      allow(Captain::Copilot::ResponseJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, 'queue offline')

      expect { expect(source.schedule_response!).to eq(:failed) }.to change(described_class, :count).by(1)

      expect(source.reload).to be_response_released
      expect(source.copilot_response.message['content']).to eq(
        I18n.t('captain.copilot_generation_failed', default: 'Copilot could not generate a response. Please try again.')
      )
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(0)

      expect { source.persist_failure_response! }.not_to change(described_class, :count)
    end
  end

  describe 'ordered claiming' do
    it 'rejects forged tokens and blocks later messages behind earlier work' do
      first = create_source('first')
      second = create_source('second')
      first.reserve_response!
      second.reserve_response!

      expect(first.claim_response!(SecureRandom.uuid)).to eq(:invalid)
      expect(second.claim_response!(second.response_job_token)).to eq(:out_of_order)
      expect(first.claim_response!(first.response_job_token)).to eq(:claimed)
      expect(first.reload.response_attempts).to eq(1)
    end

    it 'allows the next message after the earlier response reaches a terminal state' do
      first = create_source('first')
      second = create_source('second')
      first.reserve_response!
      second.reserve_response!
      first.claim_response!(first.response_job_token)
      first.complete_response!

      expect(second.claim_response!(second.response_job_token)).to eq(:claimed)
    end
  end

  describe 'response integrity' do
    it 'allows the documented boolean reply_suggestion shape' do
      message = build(
        :captain_copilot_message,
        copilot_thread: copilot_thread,
        message_type: :assistant,
        message: { content: 'Draft', reasoning: 'Grounded', reply_suggestion: false }
      )

      expect(message).to be_valid
    end

    it 'rejects arbitrary keys, non-boolean flags and oversized values' do
      message = build(
        :captain_copilot_message,
        copilot_thread: copilot_thread,
        message: {
          content: 'x' * (described_class::VALUE_BYTES_LIMIT + 1),
          reply_suggestion: 'false',
          secret: 'not allowed'
        }
      )

      expect(message).not_to be_valid
      expect(message.errors[:message]).to include(
        'contains invalid attributes: secret',
        'contains invalid value types',
        'contains an oversized value'
      )
    end

    it 'rejects cross-account conversation and response source links' do
      other_account = create(:account)
      other_conversation = create(:conversation, account: other_account)
      other_source = create(:captain_copilot_message)
      message = build(
        :captain_copilot_message,
        copilot_thread: copilot_thread,
        conversation: other_conversation,
        source_message: other_source,
        message_type: :assistant
      )

      expect(message).not_to be_valid
      expect(message.errors[:conversation]).to include('must belong to the message account')
      expect(message.errors[:source_message]).to include('must be a user message in the same thread and account')
    end

    it 'rejects a user message masquerading as a response to another source' do
      source = create_source
      message = build(
        :captain_copilot_message,
        copilot_thread: copilot_thread,
        source_message: source,
        message_type: :user,
        message: { content: 'forged user response' }
      )

      expect(message).not_to be_valid
      expect(message.errors[:source_message]).to include('must be a user message in the same thread and account')
    end

    it 'enforces a single final assistant response for each source at the database boundary' do
      source = create_source
      create(
        :captain_copilot_message,
        copilot_thread: copilot_thread,
        source_message: source,
        message_type: :assistant,
        message: { content: 'first response' }
      )

      expect do
        create(
          :captain_copilot_message,
          copilot_thread: copilot_thread,
          source_message: source,
          message_type: :assistant,
          message: { content: 'duplicate response' }
        )
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
