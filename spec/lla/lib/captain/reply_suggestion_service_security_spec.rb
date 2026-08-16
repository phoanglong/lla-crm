require 'rails_helper'

RSpec.describe Captain::ReplySuggestionService do
  subject(:service) do
    service_class.new(account: account, conversation_display_id: conversation.display_id, user: user)
  end

  let(:service_class) do
    Class.new(described_class) do
      def make_api_call(**)
        { message: 'Suggested' }
      end
    end
  end
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  before do
    allow(account).to receive(:feature_enabled?).and_call_original
    allow(account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
  end

  it 'revalidates conversation access before formatting or calling a provider' do
    formatter = class_double(LlmFormatter::ConversationLlmFormatter)
    stub_const('LlmFormatter::ConversationLlmFormatter', formatter)
    allow(formatter).to receive(:new)

    result = service.perform

    expect(result).to include(error: 'Conversation is unavailable', error_code: 404)
    expect(formatter).not_to have_received(:new)
  end

  it 'allows an agent with current inbox access' do
    create(:inbox_member, inbox: inbox, user: user)

    expect(service.perform).to eq(message: 'Suggested')
  end

  it 'binds documentation search to the assistant configured on the conversation inbox' do
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    create(:inbox_member, inbox: inbox, user: user)

    tool = service.send(:build_search_tool)

    expect(tool.instance_variable_get(:@account)).to eq(account)
    expect(tool.instance_variable_get(:@assistant)).to eq(assistant)
    expect(service.send(:use_search_tool?)).to be(true)
  end

  it 'does not enable documentation search without the account capability' do
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    allow(account).to receive(:feature_enabled?).with('captain_tasks').and_return(false)

    expect(service.send(:use_search_tool?)).to be(false)
  end

  it 'loads the LLA extension exactly once' do
    expect(described_class.ancestors.count(Lla::Captain::ReplySuggestionService)).to eq(1)
  end
end
