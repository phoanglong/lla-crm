require 'rails_helper'

RSpec.describe Captain::AgentSession, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  it 'derives the account from the assistant' do
    conversation = create(:conversation, account: account)
    session = build(:captain_agent_session, assistant: assistant, account: create(:account), subject: conversation)

    expect(session).to be_valid
    expect(session.account_id).to eq(account.id)
  end

  it 'rejects a copilot user outside the account' do
    foreign_user = create(:user, account: create(:account))
    thread = create(:captain_copilot_thread, account: account, assistant: assistant)
    session = build(
      :captain_agent_session,
      :copilot,
      assistant: assistant,
      account: account,
      user: foreign_user,
      subject: thread
    )

    expect(session).not_to be_valid
    expect(session.errors[:user]).to include('must belong to the session account')
  end

  it 'rejects a copilot thread owned by another assistant' do
    user = create(:user, account: account)
    other_assistant = create(:captain_assistant, account: account)
    thread = create(:captain_copilot_thread, account: account, user: user, assistant: other_assistant)
    session = build(:captain_agent_session, :copilot, assistant: assistant, account: account, user: user, subject: thread)

    expect(session).not_to be_valid
    expect(session.errors[:subject]).to include('must use the session assistant and user')
  end

  it 'rejects a result from another subject in the same account' do
    conversation = create(:conversation, account: account)
    other_conversation = create(:conversation, account: account)
    message = create(:message, account: account, conversation: other_conversation)
    session = build(:captain_agent_session, assistant: assistant, account: account, subject: conversation, result: message)

    expect(session).not_to be_valid
    expect(session.errors[:result]).to include('must belong to the session subject')
  end

  it 'bounds persisted run context and citation identifiers' do
    conversation = create(:conversation, account: account)
    session = build(:captain_agent_session, assistant: assistant, account: account, subject: conversation,
                                            faq_ids: Array.new(101, 1), run_context: { data: 'x' * 65_536 })

    expect(session).not_to be_valid
    expect(session.errors[:faq_ids]).to be_present
    expect(session.errors[:run_context]).to be_present
  end
end
