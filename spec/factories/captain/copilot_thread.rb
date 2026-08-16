FactoryBot.define do
  factory :captain_copilot_thread, class: 'CopilotThread' do
    account
    user { association(:user, account: account) }
    title { Faker::Lorem.sentence }
    assistant { create(:captain_assistant, account: account) }
  end
end
