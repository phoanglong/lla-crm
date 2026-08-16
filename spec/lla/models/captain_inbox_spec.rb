require 'rails_helper'

RSpec.describe CaptainInbox, type: :model do
  it 'accepts an assistant and inbox from the same account' do
    account = create(:account)
    assistant = create(:captain_assistant, account: account)
    inbox = create(:inbox, account: account)

    expect(build(:captain_inbox, captain_assistant: assistant, inbox: inbox)).to be_valid
  end

  it 'rejects an assistant and inbox from different accounts' do
    assistant = create(:captain_assistant)
    inbox = create(:inbox)

    captain_inbox = build(:captain_inbox, captain_assistant: assistant, inbox: inbox)

    expect(captain_inbox).not_to be_valid
    expect(captain_inbox.errors[:inbox]).to include('must belong to the same account as the assistant')
  end
end
