FactoryBot.define do
  factory :captain_message_report, class: 'Captain::MessageReport' do
    transient do
      report_account { create(:account) }
      report_conversation { create(:conversation, account: report_account) }
      report_assistant { create(:captain_assistant, account: report_account) }
    end

    report_reason { 'incorrect_information' }
    description { 'The generated citation is wrong.' }
    message do
      create(
        :message,
        account: report_account,
        conversation: report_conversation,
        sender: report_assistant,
        message_type: :outgoing,
        private: false
      )
    end
    user { create(:user, account: report_account) }
  end
end
