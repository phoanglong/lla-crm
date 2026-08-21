# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::Captain::ResponseCoordination, type: :service do
  it 'uses account and conversation boundaries in both coordination keys' do
    expect(described_class.schedule_key(account_id: 7, conversation_id: 11))
      .to eq('LLA_CAPTAIN_RESPONSE_SCHEDULE::7::11')
    expect(described_class.execution_key(account_id: 7, conversation_id: 11))
      .to eq('LLA_CAPTAIN_RESPONSE_EXECUTION::7::11')
  end

  it 'embeds the triggering message id in an opaque scheduling token' do
    token = described_class.scheduling_token(42)

    expect(described_class.scheduled_message_id(token)).to eq(42)
    expect(token).to match(/\A42:[a-f0-9]{32}\z/)
  end

  it 'rejects malformed scheduling tokens' do
    expect(described_class.scheduled_message_id('not-a-token')).to be_nil
  end
end
