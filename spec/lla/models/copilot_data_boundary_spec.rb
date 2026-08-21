require 'rails_helper'

RSpec.describe 'LLA Copilot data boundary', type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, account: account) }

  it 'derives thread account from its assistant and requires user membership' do
    foreign_user = create(:user, account: create(:account))
    thread = build(:captain_copilot_thread, assistant: assistant, account: create(:account), user: foreign_user)

    expect(thread).not_to be_valid
    expect(thread.account_id).to eq(account.id)
    expect(thread.errors[:user]).to include('must belong to the thread account')
  end

  it 'derives message account from its thread' do
    thread = create(:captain_copilot_thread, account: account, assistant: assistant, user: user)
    message = build(:captain_copilot_message, account: create(:account), copilot_thread: thread)

    expect(message).to be_valid
    expect(message.account_id).to eq(account.id)
  end

  it 'rejects unknown, non-string and oversized message values' do
    thread = create(:captain_copilot_thread, account: account, assistant: assistant, user: user)
    message = build(:captain_copilot_message, copilot_thread: thread,
                                              message: { content: ['unsafe'], secret: 'x', reasoning: 'x' * 32_769 })

    expect(message).not_to be_valid
    expect(message.errors[:message]).to include('contains invalid attributes: secret')
    expect(message.errors[:message]).to include('contains invalid value types')
    expect(message.errors[:message]).to include('contains an oversized value')
  end

  it 'bounds previous history while preserving chronological roles' do
    thread = create(:captain_copilot_thread, account: account, assistant: assistant, user: user)
    45.times do |index|
      create(:captain_copilot_message, copilot_thread: thread, message_type: index.even? ? :user : :assistant,
                                       message: { content: "message-#{index}" })
    end

    history = thread.previous_history
    expect(history.length).to eq(CopilotThread::HISTORY_MESSAGE_LIMIT)
    expect(history.first[:content]).to eq('message-5')
    expect(history.last[:content]).to eq('message-44')
  end
end
