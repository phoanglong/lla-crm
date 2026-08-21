require 'rails_helper'

RSpec.describe Captain::Assistant::SessionPresenter do
  subject(:messages) { described_class.new(session).run_context }

  let(:session) { instance_double(Captain::AgentSession, run_context: run_context) }
  let(:run_context) do
    {
      'messages' => [
        { role: 'system', content: 'secret instructions' },
        { role: 'user', content: 'x' * 5_000, unexpected: 'private' },
        { role: 'assistant', content: { text: 'answer', reasoning: 'private', attachments: Array.new(9, 'url') },
          agent_name: 'scenario_1_refund_agent', tool_calls: [{ arguments: { token: 'secret' } }] }
      ]
    }
  end

  it 'returns only bounded disclosure-safe fields' do
    expect(messages.length).to eq(2)
    expect(messages.first).to eq(role: 'user', content: 'x' * 4_096)
    expect(messages.second).to eq(
      role: 'assistant',
      content: { text: 'answer', attachments: Array.new(6) { { type: 'image' } } },
      agent_name: 'scenario_1_refund_agent'
    )
    expect(messages.to_json).not_to include('secret instructions', 'reasoning', 'token', 'url')
  end

  it 'normalizes bounded legacy array records' do
    allow(session).to receive(:run_context).and_return([{ role: 'assistant', content: 'legacy' }])

    expect(messages).to eq([{ role: 'assistant', content: 'legacy' }])
  end
end
