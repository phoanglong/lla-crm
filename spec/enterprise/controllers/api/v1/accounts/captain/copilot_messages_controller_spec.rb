require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::CopilotMessagesController', type: :request do
  let(:account) { create(:account, limits: { captain_responses: 10 }) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user) }
  let!(:copilot_message) { create(:captain_copilot_message, copilot_thread: copilot_thread, account: account) }

  def endpoint(thread = copilot_thread)
    "/api/v1/accounts/#{account.id}/captain/copilot_threads/#{thread.id}/copilot_messages"
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/copilot_threads/{thread.id}/copilot_messages' do
    it 'returns the current user thread messages' do
      get endpoint, headers: user.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].pluck('id')).to eq([copilot_message.id])
    end

    it 'returns not found for an unknown thread' do
      get endpoint(CopilotThread.new(id: 999_999_999)), headers: user.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/copilot_threads/{thread.id}/copilot_messages' do
    it 'persists the source, reserves quota and queues only immutable identifiers' do
      private_content = 'Private customer message that must never enter the job payload'

      expect do
        post endpoint, params: { message: private_content }, headers: user.create_new_auth_token, as: :json
      end.to change(CopilotMessage, :count).by(1)

      expect(response).to have_http_status(:success)
      source = CopilotMessage.order(:id).last
      expect(source).to have_attributes(
        message: { 'content' => private_content },
        message_type: 'user',
        copilot_thread_id: copilot_thread.id,
        response_state: 'reserved'
      )
      # Wave E5 moved Captain quota out of `account.custom_attributes` and into the
      # LLA ledger (`lla_captain_quota_ledgers`), so the old counter is never written
      # and reads back nil — an assertion against it passes for nothing. These read the
      # ledger through the public accessor instead.
      expect(account.reload.usage_limits.dig(:captain, :responses)).to include(consumed: 0, reserved: 1)
      expect(Captain::Copilot::ResponseJob).to have_been_enqueued.with(
        message_id: source.id,
        reservation_token: source.response_job_token
      )

      queued_response = enqueued_jobs.find { |job| job[:job] == Captain::Copilot::ResponseJob }
      expect(queued_response.fetch(:args).to_json).not_to include(private_content)
    end

    it 'persists an idempotent limit response without enqueuing when quota is exhausted' do
      account.update!(limits: { captain_responses: 1 }, custom_attributes: { captain_responses_usage: 1 })

      expect do
        post endpoint, params: { message: 'One more request' }, headers: user.create_new_auth_token, as: :json
      end.to change(CopilotMessage, :count).by(2)

      expect(response).to have_http_status(:success)
      source = CopilotMessage.user.order(:id).last
      expect(source).to be_response_none
      expect(source.copilot_response.message['content']).to eq(I18n.t('captain.copilot_limit'))
      expect(Captain::Copilot::ResponseJob).not_to have_been_enqueued
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(1)
    end

    it 'rejects structured or blank input instead of coercing it into a prompt' do
      expect do
        post endpoint, params: { message: { content: 'nested' } }, headers: user.create_new_auth_token, as: :json
      end.not_to change(CopilotMessage, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Captain::Copilot::ResponseJob).not_to have_been_enqueued
    end

    it 'returns not found when the thread belongs to another user' do
      another_user = create(:user, account: account)
      another_thread = create(:captain_copilot_thread, account: account, user: another_user)

      post endpoint(another_thread), params: { message: 'Test message' }, headers: user.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'does not reserve quota for a conversation the agent cannot access' do
      agent = create(:user, account: account, role: :agent)
      agent_thread = create(:captain_copilot_thread, account: account, user: agent)
      inaccessible_conversation = create(:conversation, account: account)

      expect do
        post endpoint(agent_thread),
             params: { message: 'Reveal another inbox', conversation_id: inaccessible_conversation.display_id },
             headers: agent.create_new_auth_token,
             as: :json
      end.not_to change(CopilotMessage, :count)

      expect(response).to have_http_status(:not_found)
      expect(account.reload.custom_attributes['captain_responses_usage']).to be_nil
      expect(Captain::Copilot::ResponseJob).not_to have_been_enqueued
    end
  end
end
