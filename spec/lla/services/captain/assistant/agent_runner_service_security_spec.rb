require 'rails_helper'

RSpec.describe Captain::Assistant::AgentRunnerService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    stub_request(:get, 'https://example.test/image?token=secret')
      .to_return(status: 200, body: 'image-bytes', headers: { 'Content-Type' => 'image/jpeg' })
    allow(ChatwootExceptionTracker).to receive(:new).and_return(
      instance_double(ChatwootExceptionTracker, capture_exception: true)
    )
    allow(Rails.logger).to receive(:error)
  end

  it 'fails closed before constructing a runner for a cross-account conversation' do
    foreign_conversation = create(:conversation, account: create(:account))
    service = described_class.new(assistant: assistant, conversation: foreign_conversation)

    expect(Agents::Runner).not_to receive(:with_agents)
    expect(service.generate_response(message_history: [{ role: 'user', content: 'secret text' }])).to eq(
      'response' => 'conversation_handoff',
      'reasoning' => 'Agent runtime unavailable',
      'handoff_tool_called' => false
    )
  end

  it 'uses an unpredictable correlation ID for playground runs' do
    service = described_class.new(assistant: assistant)

    first_id = service.send(:build_context, [])[:session_id]
    second_id = service.send(:build_context, [])[:session_id]

    expect(first_id).not_to eq(second_id)
    expect(first_id).to start_with("#{account.id}_playground_")
  end

  it 'records trace metadata without raw message content or attachment URLs' do
    service = described_class.new(assistant: assistant, conversation: conversation)
    history = [{ role: 'user', content: [{ type: 'text', text: 'private-token-123' },
                                         { type: 'image_url', image_url: { url: 'https://example.test/image?token=secret' } }] }]

    _message, context = service.send(:run_payload, history)
    trace = context[:captain_v2_trace_input]

    expect(trace).to include('"message_count":1', '"multimodal":true')
    expect(trace).not_to include('private-token-123', 'example.test', 'token=secret')
  end

  it 'terminates tool execution after the bounded callback budget' do
    service = described_class.new(assistant: assistant, conversation: conversation)
    wrapper = Struct.new(:context).new({})

    described_class::MAX_TOOL_CALLS.times do
      service.send(:track_tool_usage, 'faq_lookup', 'handoff', wrapper)
    end

    expect do
      service.send(:track_tool_usage, 'faq_lookup', 'handoff', wrapper)
    end.to raise_error(described_class::ToolBudgetExceededError)
  end

  it 'bounds provider output before returning it to the job' do
    service = described_class.new(assistant: assistant, conversation: conversation)
    result = instance_double(Agents::RunResult, output: { response: 'x' * 20_000, reasoning: 'r' * 8_000 }, context: nil)

    response = service.send(:process_agent_result, result)

    expect(response['response'].bytesize).to eq(described_class::MAX_TEXT_BYTES)
    expect(response['reasoning'].bytesize).to eq(described_class::MAX_REASONING_BYTES)
  end
end
