require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::CopilotThreads', type: :request do
  let(:account) { create(:account, limits: { captain_responses: 10 }) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:valid_params) do
    { message: 'Hello, how can you help me?', assistant_id: assistant.id, conversation_id: conversation.display_id }
  end

  before do
    create(:inbox_member, user: agent, inbox: conversation.inbox)
  end

  def endpoint
    "/api/v1/accounts/#{account.id}/captain/copilot_threads"
  end

  def json_response
    response.parsed_body.deep_symbolize_keys
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/copilot_threads' do
    it 'requires authentication' do
      get endpoint, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns only current-user threads in reverse creation order' do
      threads = create_list(:captain_copilot_thread, 3, account: account, user: agent)
      create_list(:captain_copilot_thread, 2, account: account, user: admin)

      get endpoint, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:payload].pluck(:id)).to eq(threads.reverse.pluck(:id))
      expect(json_response[:payload].map { |thread| thread.dig(:user, :id) }.uniq).to eq([agent.id])
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/copilot_threads' do
    it 'requires authentication' do
      post endpoint, params: valid_params, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects blank or structured messages' do
      ['', { content: 'nested prompt' }].each do |invalid_message|
        post endpoint,
             params: { message: invalid_message, assistant_id: assistant.id },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      expect(CopilotThread.count).to eq(0)
      expect(Captain::Copilot::ResponseJob).not_to have_been_enqueued
    end

    it 'returns not found for an assistant outside the current account' do
      foreign_assistant = create(:captain_assistant)

      post endpoint,
           params: { message: 'Hello', assistant_id: foreign_assistant.id },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'creates a bounded thread, reserves quota and queues only source identifiers' do
      private_content = 'Customer context that must not be serialized into ActiveJob'

      expect do
        post endpoint,
             params: valid_params.merge(message: private_content),
             headers: agent.create_new_auth_token,
             as: :json
      end.to change(CopilotThread, :count).by(1).and change(CopilotMessage, :count).by(1)

      expect(response).to have_http_status(:success)
      thread = CopilotThread.order(:id).last
      source = thread.copilot_messages.sole
      expect(thread).to have_attributes(title: private_content, user_id: agent.id, assistant_id: assistant.id)
      expect(source).to have_attributes(
        message: { 'content' => private_content },
        conversation_id: conversation.id,
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

    it 'keeps the full bounded prompt while truncating only the display title' do
      long_message = 'a' * (CopilotThread::TITLE_LENGTH_LIMIT + 20)

      post endpoint,
           params: valid_params.merge(message: long_message),
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      thread = CopilotThread.order(:id).last
      expect(thread.title.bytesize).to eq(CopilotThread::TITLE_LENGTH_LIMIT)
      expect(thread.copilot_messages.user.sole.message['content']).to eq(long_message)
    end

    it 'persists a limit response and leaves usage unchanged when quota is exhausted' do
      account.update!(limits: { captain_responses: 2 }, custom_attributes: { captain_responses_usage: 2 })

      expect do
        post endpoint, params: valid_params, headers: agent.create_new_auth_token, as: :json
      end.to change(CopilotThread, :count).by(1).and change(CopilotMessage, :count).by(2)

      expect(response).to have_http_status(:success)
      source = CopilotThread.order(:id).last.copilot_messages.user.sole
      expect(source).to be_response_none
      expect(source.copilot_response.message['content']).to eq(I18n.t('captain.copilot_limit'))
      expect(Captain::Copilot::ResponseJob).not_to have_been_enqueued
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(2)
    end

    it 'does not create or reserve for a conversation outside the agent inboxes' do
      inaccessible_conversation = create(:conversation, account: account)

      expect do
        post endpoint,
             params: valid_params.merge(conversation_id: inaccessible_conversation.display_id),
             headers: agent.create_new_auth_token,
             as: :json
      end.not_to change(CopilotThread, :count)

      expect(response).to have_http_status(:not_found)
      expect(account.reload.custom_attributes['captain_responses_usage']).to be_nil
      expect(Captain::Copilot::ResponseJob).not_to have_been_enqueued
    end
  end
end
