require 'rails_helper'

RSpec.describe Captain::Llm::AssistantFalsePromiseService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant: assistant, conversation: conversation) }
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:mock_response) do
    instance_double(
      RubyLLM::Message,
      content: { 'decision' => 'safe', 'reason' => 'safe_response' }
    )
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_schema).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
  end

  describe '#detect' do
    let(:message_history) do
      [
        { role: 'user', content: 'Can you fix this later?' },
        { role: 'assistant', content: 'I can help with known troubleshooting steps.' }
      ]
    end

    it 'uses the detector model even when the assistant feature model is overridden' do
      account.update!(captain_models: { 'assistant' => 'gpt-5-mini' })

      expect(RubyLLM).to receive(:chat).with(model: 'gpt-5.2').and_return(mock_chat)
      allow(mock_chat).to receive(:ask).and_return(mock_response)

      result = service.detect(message_history: message_history, assistant_response: 'Try restarting the app.')

      expect(result).to include('model' => 'gpt-5.2')
    end

    it 'uses the false promise schema and detector prompt' do
      expect(mock_chat).to receive(:with_schema).with(Captain::AssistantFalsePromiseSchema).and_return(mock_chat)
      expect(mock_chat).to receive(:with_instructions).with(
        a_string_including('future work', 'future_work_promise')
      ).and_return(mock_chat)
      expect(mock_chat).to receive(:ask).with(
        a_string_including(
          '<conversation_context>',
          'User: Can you fix this later?',
          '<assistant_response_to_check>',
          'Try restarting the app.'
        )
      ).and_return(mock_response)

      result = service.detect(message_history: message_history, assistant_response: 'Try restarting the app.')

      expect(result).to include('decision' => 'safe', 'reason' => 'safe_response')
    end

    it 'uses deterministic temperature and parses fenced JSON output' do
      response = instance_double(
        RubyLLM::Message,
        content: "```json\n{\"decision\":\"safe\",\"reason\":\"safe_response\"}\n```"
      )

      expect(mock_chat).to receive(:with_temperature).with(0.0).and_return(mock_chat)
      allow(mock_chat).to receive(:ask).and_return(response)

      expect(service.detect(message_history: message_history, assistant_response: 'Try restarting.')).to include(
        'decision' => 'safe', 'reason' => 'safe_response'
      )
    end

    it 'fails closed when the provider returns a value outside the schema enum' do
      response = instance_double(RubyLLM::Message, content: { 'decision' => 'unsafe', 'reason' => 'anything' })
      allow(mock_chat).to receive(:ask).and_return(response)

      expect(service.detect(message_history: message_history, assistant_response: 'I will check later.')).to include(
        'decision' => nil, 'reason' => nil, 'error' => 'invalid_false_promise_response'
      )
    end
  end

  it 'rejects a conversation from another account before sending data to the LLM' do
    other_conversation = create(:conversation)

    expect do
      described_class.new(assistant: assistant, conversation: other_conversation)
    end.to raise_error(ArgumentError, /same account/)
  end
end
