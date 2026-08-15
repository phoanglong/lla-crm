require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Assistants', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants' do
    context 'when it is an un-authenticated user' do
      it 'does not fetch assistants' do
        get "/api/v1/accounts/#{account.id}/captain/assistants",
            as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'fetches assistants for the account' do
        create_list(:captain_assistant, 3, account: account)
        get "/api/v1/accounts/#{account.id}/captain/assistants",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:payload].length).to eq(3)
        expect(json_response[:meta]).to eq(
          { total_count: 3, page: 1 }
        )
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants/{id}' do
    let(:assistant) { create(:captain_assistant, account: account) }

    context 'when it is an un-authenticated user' do
      it 'does not fetch the assistant' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
            as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'fetches the assistant' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:id]).to eq(assistant.id)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/assistants' do
    let(:valid_attributes) do
      {
        assistant: {
          name: 'New Assistant',
          description: 'Assistant Description',
          response_guidelines: ['Be helpful', 'Be concise'],
          guardrails: ['No harmful content', 'Stay on topic'],
          config: {
            product_name: 'Chatwoot',
            feature_faq: true,
            feature_memory: false,
            feature_citation: true
          }
        }
      }
    end

    context 'when it is an un-authenticated user' do
      it 'does not create an assistant' do
        post "/api/v1/accounts/#{account.id}/captain/assistants",
             params: valid_attributes,
             as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'does not create an assistant' do
        post "/api/v1/accounts/#{account.id}/captain/assistants",
             params: valid_attributes,
             headers: agent.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'creates a new assistant' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: valid_attributes,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        expect(json_response[:name]).to eq('New Assistant')
        expect(json_response[:response_guidelines]).to eq(['Be helpful', 'Be concise'])
        expect(json_response[:guardrails]).to eq(['No harmful content', 'Stay on topic'])
        expect(json_response[:config][:product_name]).to eq('Chatwoot')
        expect(json_response[:config][:feature_citation]).to be(true)
        expect(response).to have_http_status(:success)
      end

      it 'creates an assistant with feature_citation disabled' do
        attributes_with_disabled_citation = valid_attributes.deep_dup
        attributes_with_disabled_citation[:assistant][:config][:feature_citation] = false

        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants",
               params: attributes_with_disabled_citation,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Captain::Assistant, :count).by(1)

        expect(json_response[:config][:feature_citation]).to be(false)
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/captain/assistants/{id}' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:update_attributes) do
      {
        assistant: {
          name: 'Updated Assistant',
          response_guidelines: ['Updated guideline'],
          guardrails: ['Updated guardrail'],
          config: {
            feature_citation: false
          }
        }
      }
    end

    context 'when it is an un-authenticated user' do
      it 'does not update the assistant' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: update_attributes,
              as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'does not update the assistant' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: update_attributes,
              headers: agent.create_new_auth_token,
              as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'updates the assistant' do
        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: update_attributes,
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:name]).to eq('Updated Assistant')
        expect(json_response[:response_guidelines]).to eq(['Updated guideline'])
        expect(json_response[:guardrails]).to eq(['Updated guardrail'])
      end

      it 'updates only response_guidelines when only that is provided' do
        assistant.update!(response_guidelines: ['Original guideline'], guardrails: ['Original guardrail'])
        original_name = assistant.name

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { response_guidelines: ['New guideline only'] } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:name]).to eq(original_name)
        expect(json_response[:response_guidelines]).to eq(['New guideline only'])
        expect(json_response[:guardrails]).to eq(['Original guardrail'])
      end

      it 'updates only guardrails when only that is provided' do
        assistant.update!(response_guidelines: ['Original guideline'], guardrails: ['Original guardrail'])
        original_name = assistant.name

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { guardrails: ['New guardrail only'] } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:name]).to eq(original_name)
        expect(json_response[:response_guidelines]).to eq(['Original guideline'])
        expect(json_response[:guardrails]).to eq(['New guardrail only'])
      end

      it 'updates feature_citation config' do
        assistant.update!(config: { 'feature_citation' => true })

        patch "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
              params: { assistant: { config: { feature_citation: false } } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:config][:feature_citation]).to be(false)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/captain/assistants/{id}' do
    let!(:assistant) { create(:captain_assistant, account: account) }

    context 'when it is an un-authenticated user' do
      it 'does not delete the assistant' do
        delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
               as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'delete the assistant' do
        delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
               headers: agent.create_new_auth_token,
               as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      it 'deletes the assistant' do
        expect do
          delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}",
                 headers: admin.create_new_auth_token,
                 as: :json
        end.to change(Captain::Assistant, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/assistants/{id}/faq_stats' do
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'returns approved FAQ, open suggestion, document counts and coverage' do
      create_list(:captain_assistant_response, 3, assistant: assistant, account: account, status: :approved)
      assistant.faq_suggestions.create!(question: 'How do I enable the feature?', answer: 'Turn it on in settings.')
      create_list(:captain_document, 2, assistant: assistant, account: account)

      get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/faq_stats",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to eq(approved: 3, suggestions: 1, documents: 2, coverage: 75)
    end

    it 'returns zero coverage when there are no FAQs or suggestions' do
      get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/faq_stats",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(approved: 0, suggestions: 0, coverage: 0)
    end

    it 'counts only suggestions backed by conversations the agent can access' do
      accessible_inbox = create(:inbox, account: account)
      hidden_inbox = create(:inbox, account: account)
      create(:inbox_member, user: agent, inbox: accessible_inbox)
      create(:captain_assistant_response, assistant: assistant, account: account, status: :approved)

      accessible_suggestion = assistant.faq_suggestions.create!(question: 'Visible question', answer: 'Visible answer')
      accessible_suggestion.observations.create!(
        conversation: create(:conversation, account: account, inbox: accessible_inbox),
        generated_question: accessible_suggestion.question,
        generated_answer: accessible_suggestion.answer,
        language: accessible_suggestion.language
      )
      hidden_suggestion = assistant.faq_suggestions.create!(question: 'Hidden question', answer: 'Hidden answer')
      hidden_suggestion.observations.create!(
        conversation: create(:conversation, account: account, inbox: hidden_inbox),
        generated_question: hidden_suggestion.question,
        generated_answer: hidden_suggestion.answer,
        language: hidden_suggestion.language
      )

      get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/faq_stats",
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(approved: 1, suggestions: 1, coverage: 50)
    end
  end
end
