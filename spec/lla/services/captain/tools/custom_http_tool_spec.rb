require 'rails_helper'

RSpec.describe Captain::Tools::CustomHttpTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:custom_tool) { create(:captain_custom_tool, account: account) }

  around do |example|
    previous_value = ENV.fetch(Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG, nil)
    ENV[Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG] = 'true'
    example.run
  ensure
    previous_value.nil? ? ENV.delete(Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG) : ENV[Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG] = previous_value
  end

  before do
    account.enable_features!('custom_tools')
    allow(ChatwootApp).to receive(:otel_enabled?).and_return(false)
  end

  it 'is active only for an enabled, valid tool in the assistant account' do
    expect(described_class.new(assistant, custom_tool)).to be_active

    custom_tool.update!(enabled: false)
    expect(described_class.new(assistant, custom_tool)).not_to be_active

    foreign_tool = create(:captain_custom_tool)
    expect(described_class.new(assistant, foreign_tool)).not_to be_active
  end

  it 'requires the conversation inbox to be assigned to the assistant' do
    conversation = create(:conversation, account: account)
    service = described_class.new(assistant, custom_tool, conversation: conversation)

    expect(service).not_to be_active

    create(:captain_inbox, captain_assistant: assistant, inbox: conversation.inbox)
    expect(service).to be_active
  end

  it 'fails closed when the account feature is disabled through another model instance' do
    Account.find(account.id).disable_features!('custom_tools')

    expect(described_class.new(assistant, custom_tool)).not_to be_active
  end

  it 'delegates through the hardened HTTP tool without direct contact PII' do
    conversation = create(:conversation, account: account)
    conversation.contact.update!(email: 'private@example.test', phone_number: '+61400000000')
    create(:captain_inbox, captain_assistant: assistant, inbox: conversation.inbox)
    http_tool = instance_double(Captain::Tools::HttpTool)
    allow(Captain::Tools::HttpTool).to receive(:new).with(assistant, custom_tool).and_return(http_tool)
    allow(http_tool).to receive(:perform) do |context, **params|
      expect(params).to eq(order_id: '123')
      expect(context.state[:contact]).to eq(id: conversation.contact_id)
      expect(context.state.to_s).not_to include('private@example.test', '+61400000000')
      'safe result'
    end

    result = described_class.new(assistant, custom_tool, conversation: conversation).execute(order_id: '123')

    expect(result).to eq('safe result')
    expect(http_tool).to have_received(:perform)
  end

  it 'fails closed without invoking the HTTP adapter when the kill switch is off' do
    ENV[Captain::Assistant::CUSTOM_HTTP_TOOLS_FLAG] = 'false'
    expect(Captain::Tools::HttpTool).not_to receive(:new)

    result = described_class.new(assistant, custom_tool).execute(order_id: '123')

    expect(result).to eq('An error occurred while executing the request')
  end
end
