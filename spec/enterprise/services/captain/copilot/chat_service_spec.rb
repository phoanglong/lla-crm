require 'rails_helper'

RSpec.describe Captain::Copilot::ChatService do
  let(:account) { create(:account, limits: { captain_responses: 10 }, custom_attributes: { plan_name: 'startups' }) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:source_message) do
    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      conversation: conversation,
      message: { 'content' => 'Private customer question' },
      message_type: :user
    ).tap do |message|
      message.reserve_response!
      message.claim_response!(message.response_job_token)
    end
  end
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:response_content) { '{ "content": "Hey", "reasoning": "Test reasoning", "reply_suggestion": false }' }
  let(:mock_response) { instance_double(RubyLLM::Message, content: response_content) }

  before do
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPEN_AI_API_KEY').update!(value: 'test-key')

    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_params).and_return(mock_chat)
    allow(mock_chat).to receive(:with_tool).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:add_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_end_message).and_return(mock_chat)
    allow(mock_chat).to receive(:on_tool_call).and_return(mock_chat)
    allow(mock_chat).to receive(:on_tool_result).and_return(mock_chat)
    allow(mock_chat).to receive(:messages).and_return([])
    allow(mock_chat).to receive(:ask).and_return(mock_response)
  end

  describe '#initialize' do
    it 'derives the complete tenant context from the persisted source message' do
      service = described_class.new(source_message)

      expect(service).to have_attributes(
        source_message: source_message,
        assistant: assistant,
        account: account,
        user: user,
        copilot_thread: copilot_thread
      )
      expect(service.previous_history).to eq([{ role: 'user', content: 'Private customer question' }])
    end

    it 'builds an injection-resistant system prompt and authorized viewing context' do
      messages = described_class.new(source_message).messages

      expect(messages.first).to include(role: 'system')
      expect(messages.first[:content]).to include('untrusted')
      expect(messages.second).to eq(role: 'system', content: "Respond in #{account.locale_english_name}.")
      viewing_context = messages.find { |message| message[:content].to_s.include?('currently viewing authorized conversation') }
      expect(viewing_context[:content]).to include(conversation.display_id.to_s, contact.id.to_s)
    end

    it 'rejects stale account membership before constructing an LLM request' do
      source_message
      AccountUser.find_by!(account: account, user: user).destroy!

      expect { described_class.new(source_message) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(RubyLLM).not_to have_received(:chat)
    end

    it 'rejects a conversation that is no longer visible to the agent' do
      source_message
      AccountUser.find_by!(account: account, user: user).update!(role: :agent)

      expect { described_class.new(source_message) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '#generate_response' do
    it 'uses the account copilot model route' do
      account.update!(captain_models: { 'copilot' => 'gpt-5.2' })

      expect(RubyLLM).to receive(:chat).with(model: 'gpt-5.2').and_return(mock_chat)

      described_class.new(source_message).generate_response
    end

    it 'normalizes, persists and links exactly one final response without consuming quota twice' do
      service = described_class.new(source_message)

      expect do
        expect(service.generate_response).to eq(
          { 'content' => 'Hey', 'reasoning' => 'Test reasoning', 'reply_suggestion' => false }
        )
      end.to change(CopilotMessage.assistant, :count).by(1)

      response = source_message.reload.copilot_response
      expect(source_message).to be_response_completed
      expect(response).to have_attributes(copilot_thread_id: copilot_thread.id, account_id: account.id)
      expect(response.message).to eq(
        'content' => 'Hey', 'reasoning' => 'Test reasoning', 'reply_suggestion' => false
      )
      expect(account.reload.custom_attributes['captain_responses_usage']).to eq(1)
    end

    it 'does not include future thread messages in the bounded request history' do
      service = described_class.new(source_message)
      later_message = create(
        :captain_copilot_message,
        account: account,
        copilot_thread: copilot_thread,
        message: { 'content' => 'A later private prompt' },
        message_type: :user
      )

      expect(service.previous_history.to_json).not_to include(later_message.message['content'])

      service.generate_response

      expect(mock_chat).not_to have_received(:add_message).with(hash_including(content: later_message.message['content']))
    end

    it 'rejects oversized model output before persisting a final response' do
      allow(mock_response).to receive(:content).and_return('x' * (Captain::ChatResponseHelper::MAX_RESPONSE_BYTES + 1))

      expect { described_class.new(source_message).generate_response }.to raise_error(ArgumentError, 'LLM response is too large')

      expect(source_message.reload).to be_response_processing
      expect(source_message.copilot_response).to be_nil
    end
  end
end
