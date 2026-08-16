# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CaptainListener do
  subject(:publish_resolution) { described_class.instance.conversation_resolved(event) }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) do
    create(:captain_assistant, account: account, config: { feature_memory: false, feature_faq: false })
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:event) { Events::Base.new(:conversation_resolved, Time.current, conversation: conversation) }

  before do
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
  end

  it 'does not run features represented by false-like configuration values' do
    assistant.update!(config: { feature_memory: 'false', feature_faq: '0' })
    allow(Rails.logger).to receive(:info).and_call_original

    expect { publish_resolution }.not_to raise_error

    expect(Rails.logger).not_to have_received(:info).with(include('resolved-conversation feature deferred'))
  end

  it 'rejects an inconsistent cross-account assistant before invoking a feature' do
    foreign_assistant = create(:captain_assistant, config: { feature_memory: true })
    allow(inbox).to receive(:captain_assistant).and_return(foreign_assistant)
    allow(conversation).to receive(:inbox).and_return(inbox)
    allow(Rails.logger).to receive(:info).and_call_original

    expect { publish_resolution }.not_to raise_error

    expect(Rails.logger).not_to have_received(:info).with(include('resolved-conversation feature deferred'))
  end

  unless ChatwootApp.enterprise?
    it 'defers E4 resolved-conversation features without raising in pure-LLA mode' do
      assistant.update!(config: { feature_memory: true, feature_faq: true })
      allow(Rails.logger).to receive(:info).and_call_original

      expect { publish_resolution }.not_to raise_error

      expect(Rails.logger).to have_received(:info).with(include('feature=contact_notes'))
      expect(Rails.logger).to have_received(:info).with(include('feature=conversation_faq'))
    end
  end
end
