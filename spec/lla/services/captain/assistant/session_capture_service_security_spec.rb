require 'rails_helper'

RSpec.describe Captain::Assistant::SessionCaptureService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:result_message) { create(:message, account: account, conversation: conversation) }
  let(:run_result) do
    Agents::RunResult.new(
      output: { 'response' => 'Done' },
      context: { conversation_history: [{ role: :user, content: 'Help' }], state: { cw_metadata: {} } }
    )
  end
  let(:service) do
    described_class.new(
      assistant: assistant,
      conversation: conversation,
      run_result: run_result,
      result_message: result_message,
      credits_consumed: 1.0
    )
  end

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    stub_request(:get, 'https://example.test/image?token=secret')
      .to_return(status: 200, body: 'image-bytes', headers: { 'Content-Type' => 'image/jpeg' })
    allow(assistant).to receive(:agent_model).and_return('gpt-5.2')
  end

  it 'is idempotent for the same effective result message' do
    expect do
      expect(service.capture).to be_persisted
      expect(service.capture).to be_persisted
    end.to change(Captain::AgentSession, :count).by(1)
  end

  it 'does not persist attachment URLs or query credentials' do
    content = RubyLLM::Content.new('Screenshot', ['https://example.test/image?token=secret'])
    run_result.context[:conversation_history] = [{ role: :user, content: content }]

    serialized_context = service.capture.run_context.to_json

    expect(serialized_context).to include('Screenshot', '"type":"image"')
    expect(serialized_context).not_to include('example.test', 'token=secret')
  end

  it 'does not capture a session for a conversation outside the assistant account' do
    foreign_conversation = create(:conversation, account: create(:account))
    foreign_service = described_class.new(
      assistant: assistant,
      conversation: foreign_conversation,
      run_result: run_result,
      result_message: nil,
      credits_consumed: 1.0
    )

    expect { foreign_service.capture }.not_to change(Captain::AgentSession, :count)
  end
end
