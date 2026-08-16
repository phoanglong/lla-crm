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

  def stub_resolved_conversation_features
    attributes = instance_double(Captain::Llm::ContactAttributesService, generate_and_update_attributes: nil)
    notes = instance_double(Captain::Llm::ContactNotesService, generate_and_update_notes: nil)
    allow(Captain::Llm::ContactAttributesService).to receive(:new).and_return(attributes)
    allow(Captain::Llm::ContactNotesService).to receive(:new).and_return(notes)
    allow(Captain::Llm::ConversationFaqJob).to receive(:perform_later)
  end

  it 'does not run features represented by false-like configuration values' do
    assistant.update!(config: { feature_memory: 'false', feature_faq: '0' })
    stub_resolved_conversation_features

    expect { publish_resolution }.not_to raise_error

    expect(Captain::Llm::ContactAttributesService).not_to have_received(:new)
    expect(Captain::Llm::ContactNotesService).not_to have_received(:new)
    expect(Captain::Llm::ConversationFaqJob).not_to have_received(:perform_later)
  end

  it 'rejects an inconsistent cross-account assistant before invoking a feature' do
    foreign_assistant = create(:captain_assistant, config: { feature_memory: true })
    allow(inbox).to receive(:captain_assistant).and_return(foreign_assistant)
    allow(conversation).to receive(:inbox).and_return(inbox)
    stub_resolved_conversation_features

    expect { publish_resolution }.not_to raise_error

    expect(Captain::Llm::ContactAttributesService).not_to have_received(:new)
    expect(Captain::Llm::ContactNotesService).not_to have_received(:new)
    expect(Captain::Llm::ConversationFaqJob).not_to have_received(:perform_later)
  end

  it 'runs LLA-owned memory and FAQ features when enabled' do
    assistant.update!(config: { feature_memory: true, feature_faq: true })
    attributes = instance_double(Captain::Llm::ContactAttributesService)
    notes = instance_double(Captain::Llm::ContactNotesService)
    allow(Captain::Llm::ContactAttributesService).to receive(:new).with(assistant, conversation).and_return(attributes)
    allow(Captain::Llm::ContactNotesService).to receive(:new).with(assistant, conversation).and_return(notes)

    expect(attributes).to receive(:generate_and_update_attributes)
    expect(notes).to receive(:generate_and_update_notes)
    expect(Captain::Llm::ConversationFaqJob).to receive(:perform_later).with(conversation, assistant)

    expect { publish_resolution }.not_to raise_error
  end
end
