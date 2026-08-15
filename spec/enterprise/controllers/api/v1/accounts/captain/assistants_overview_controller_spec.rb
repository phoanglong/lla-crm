require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Assistants', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants/{id}/summary' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:alice) { create(:user, account: account, role: :administrator, name: 'Alice Adams') }
    let(:bob) { create(:user, account: account, role: :administrator, name: 'Bob Brown') }
    let(:summary_service) { instance_double(Captain::OverviewSummaryService) }
    let(:summary_stats) do
      {
        conversations_handled: { current: 42 },
        hours_saved: { current: 12 },
        auto_resolution_rate: { current: 65.0, trend: 5.0 },
        handoff_rate: { current: 20.0, trend: -2.0 },
        reopen_rate: { current: 5.0, trend: -1.0 },
        knowledge: { coverage: 80, approved: 8, documents: 3 }
      }
    end

    def get_summary(user)
      get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/summary",
          params: { range: '30', stats: summary_stats },
          headers: user.create_new_auth_token,
          as: :json
    end

    before do
      # Test env uses a null store; swap in a real store so caching behaviour is observable.
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      allow(Captain::OverviewSummaryService).to receive(:new).and_return(summary_service)
    end

    it 'caches the summary per viewer so one user never receives another user\'s greeting' do
      allow(summary_service).to receive(:perform).and_return({ message: 'Hi Alice' })
      expect(Captain::AssistantStatsBuilder).not_to receive(:new)

      get_summary(alice)
      get_summary(alice) # served from Alice's cache, no regeneration
      get_summary(bob)   # distinct cache key, regenerated for Bob

      expect(response).to have_http_status(:success)
      expect(Captain::OverviewSummaryService).to have_received(:new).twice
      expect(Captain::OverviewSummaryService).to have_received(:new).with(hash_including(stats: summary_stats)).twice
    end

    it 'does not cache failures so a transient error is retried' do
      allow(summary_service).to receive(:perform).and_return({ error: 'LLM unavailable' })

      get_summary(alice)
      get_summary(alice)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('LLM unavailable')
      expect(Captain::OverviewSummaryService).to have_received(:new).twice
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/assistants/{id}/playground' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:valid_params) do
      {
        message_content: 'Hello assistant',
        message_history: [
          { role: 'user', content: 'Previous message' },
          { role: 'assistant', content: 'Previous response', agent_name: 'billing_scenario' }
        ]
      }
    end
    let(:chat_service) { instance_double(Captain::Llm::AssistantChatService) }
    let(:agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when captain v2 is disabled' do
      it 'generates a response with the legacy assistant chat service' do
        allow(Captain::Llm::AssistantChatService).to receive(:new).with(
          assistant: assistant,
          source: 'playground'
        ).and_return(chat_service)
        allow(chat_service).to receive(:generate_response).and_return({ content: 'Assistant response' })
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: valid_params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(chat_service).to have_received(:generate_response).with(
          additional_message: valid_params[:message_content],
          message_history: valid_params[:message_history]
        )
        expect(json_response[:content]).to eq('Assistant response')
      end

      it 'uses empty array as default' do
        params_without_history = { message_content: 'Hello assistant' }
        allow(Captain::Llm::AssistantChatService).to receive(:new).with(
          assistant: assistant,
          source: 'playground'
        ).and_return(chat_service)
        allow(chat_service).to receive(:generate_response).and_return({ content: 'Assistant response' })
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: params_without_history,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(chat_service).to have_received(:generate_response).with(
          additional_message: params_without_history[:message_content],
          message_history: []
        )
      end
    end

    context 'when captain v2 is enabled' do
      before do
        account.enable_features('captain_integration_v2')
      end

      it 'generates a response with the agent runner service' do
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).with(
          assistant: assistant,
          source: 'playground'
        ).and_return(agent_runner_service)
        allow(agent_runner_service).to receive(:generate_response).and_return({ response: 'Assistant response' })
        expect(Captain::Llm::AssistantChatService).not_to receive(:new)

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: valid_params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(agent_runner_service).to have_received(:generate_response).with(
          message_history: valid_params[:message_history] + [{ role: 'user', content: valid_params[:message_content] }]
        )
        expect(json_response[:response]).to eq('Assistant response')
      end

      it 'does not duplicate the latest user message if it is already in history' do
        params_with_latest_message = {
          message_content: 'Hello assistant',
          message_history: [{ role: 'user', content: 'Hello assistant' }]
        }
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).with(
          assistant: assistant,
          source: 'playground'
        ).and_return(agent_runner_service)
        allow(agent_runner_service).to receive(:generate_response).and_return({ response: 'Assistant response' })

        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/playground",
             params: params_with_latest_message,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(agent_runner_service).to have_received(:generate_response).with(
          message_history: params_with_latest_message[:message_history]
        )
      end
    end
  end
end
