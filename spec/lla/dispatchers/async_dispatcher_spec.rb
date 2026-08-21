# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AsyncDispatcher do
  it 'registers the Captain listener exactly once' do
    listeners = described_class.new.listeners

    expect(listeners.count(CaptainListener.instance)).to eq(1)
  end
end
