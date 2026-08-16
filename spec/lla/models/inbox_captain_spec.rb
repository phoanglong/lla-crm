# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox, type: :model do
  describe '#captain_active?' do
    let(:account) { create(:account, limits: { captain_responses: 1 }) }
    let(:inbox) { create(:inbox, account: account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    end

    it 'is active while the same-account assistant has response capacity' do
      expect(inbox.reload).to be_captain_active
      expect(inbox).to be_active_bot
    end

    it 'becomes inactive after response capacity is exhausted' do
      account.increment_response_usage

      expect(inbox.reload).not_to be_captain_active
    end

    it 'fails closed if an inconsistent cross-account association is observed' do
      allow(inbox).to receive(:captain_assistant).and_return(create(:captain_assistant))

      expect(inbox).not_to be_captain_active
    end
  end
end
