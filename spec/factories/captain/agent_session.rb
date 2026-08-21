FactoryBot.define do
  factory :captain_agent_session, class: 'Captain::AgentSession' do
    account
    association :assistant, factory: :captain_assistant
    session_type { :assistant }
    subject { create(:conversation, account: account) }

    trait :copilot do
      session_type { :copilot }
      user { association(:user, account: account) }
      subject { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
    end
  end
end
