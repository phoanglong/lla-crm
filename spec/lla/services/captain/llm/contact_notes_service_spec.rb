# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Llm::ContactNotesService, type: :service do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, custom_attributes: { 'existing' => 'preserved' }) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :resolved) }

  before do
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    conversation.resolved!
  end

  describe '#generate_and_update_notes' do
    it 'persists bounded normalized notes once across retries' do
      service = described_class.new(assistant, conversation)
      allow(service).to receive(:request_json).and_return(
        'notes' => ['  Prefers email support  ', 'Prefers email support', 7, '', 'Uses the Pro plan']
      )

      2.times { service.generate_and_update_notes }

      expect(contact.notes.order(:id).pluck(:content)).to eq(['Prefers email support', 'Uses the Pro plan'])
    end

    it 'rejects malformed output' do
      service = described_class.new(assistant, conversation)
      allow(service).to receive(:request_json).and_return('notes' => 'not-an-array')

      expect(service.generate_and_update_notes).to eq([])
      expect(contact.notes).to be_empty
    end

    it 'rejects a cross-account assistant before calling the provider' do
      service = described_class.new(create(:captain_assistant, account: create(:account)), conversation)
      allow(service).to receive(:request_json)

      expect(service.generate_and_update_notes).to eq([])
      expect(service).not_to have_received(:request_json)
    end

    it 'redacts provider exception details from logs and exception tracking' do
      service = described_class.new(assistant, conversation)
      tracker = instance_double(ChatwootExceptionTracker, capture_exception: nil)
      allow(service).to receive(:request_json).and_raise(RubyLLM::Error, 'customer-secret-value')
      allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)
      allow(Rails.logger).to receive(:warn)

      expect(service.generate_and_update_notes).to eq([])
      expect(ChatwootExceptionTracker).to have_received(:new) do |error, **|
        expect(error.message).to eq('contact_notes failed: RubyLLM::Error')
      end
      expect(Rails.logger).to have_received(:warn) do |message|
        expect(message).not_to include('customer-secret-value')
      end
    end
  end

  describe Captain::Llm::ContactAttributesService do
    let!(:text_definition) do
      create(
        :custom_attribute_definition,
        account: account,
        attribute_model: :contact_attribute,
        attribute_display_type: :text,
        attribute_key: 'support_preference'
      )
    end
    let!(:number_definition) do
      create(
        :custom_attribute_definition,
        account: account,
        attribute_model: :contact_attribute,
        attribute_display_type: :number,
        attribute_key: 'seat_count'
      )
    end
    let!(:list_definition) do
      create(
        :custom_attribute_definition,
        account: account,
        attribute_model: :contact_attribute,
        attribute_display_type: :list,
        attribute_key: 'plan',
        attribute_values: %w[starter pro]
      )
    end

    it 'atomically merges only account-owned, type-valid allowlisted attributes' do
      service = described_class.new(assistant, conversation)
      allow(service).to receive(:request_json).and_return(
        'attributes' => [
          { 'key' => text_definition.attribute_key, 'value' => ' Email ' },
          { 'key' => number_definition.attribute_key, 'value' => '25' },
          { 'key' => list_definition.attribute_key, 'value' => 'enterprise' },
          { 'key' => 'name', 'value' => 'Injected system field' },
          { 'key' => 'other_tenant_key', 'value' => 'blocked' }
        ]
      )

      expect(service.generate_and_update_attributes).to eq('support_preference' => 'Email', 'seat_count' => 25.0)
      expect(contact.reload.custom_attributes).to include(
        'existing' => 'preserved', 'support_preference' => 'Email', 'seat_count' => 25.0
      )
      expect(contact.custom_attributes).not_to include('plan', 'name', 'other_tenant_key')
    end

    it 'rejects a cross-account assistant before generating attributes' do
      service = described_class.new(create(:captain_assistant, account: create(:account)), conversation)
      allow(service).to receive(:request_json)

      expect(service.generate_and_update_attributes).to eq({})
      expect(service).not_to have_received(:request_json)
      expect(contact.reload.custom_attributes).to eq('existing' => 'preserved')
    end
  end

  describe Lla::Llm::BackgroundService do
    it 'builds a bounded context from public customer and human-agent messages only' do
      user = create(:user, account: account)
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact,
                       message_type: :incoming, content: 'public-customer-text')
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: user,
                       message_type: :outgoing, content: 'public-human-text')
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: user,
                       message_type: :outgoing, private: true, content: 'private-secret-text')
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: assistant,
                       message_type: :outgoing, content: 'captain-noise-text')
      conversation.resolved!
      service = Captain::Llm::ContactNotesService.new(assistant, conversation)
      service.send(:assign_runtime_context)

      context = service.send(:memory_context, include_notes: true)

      expect(context).to include('public-customer-text', 'public-human-text')
      expect(context).not_to include('private-secret-text', 'captain-noise-text')
      expect(context.bytesize).to be <= described_class::MAX_CONTEXT_BYTES
    end
  end

  describe Captain::Llm::SystemPromptsService do
    it 'publishes strict privacy and allowlist instructions' do
      definition = build_stubbed(
        :custom_attribute_definition,
        attribute_key: 'plan',
        attribute_display_type: :list,
        attribute_values: %w[starter pro]
      )

      attributes_prompt = described_class.attributes_generator([definition])
      notes_prompt = described_class.notes_generator('Vietnamese')

      expect(attributes_prompt).to include('plan', 'starter, pro', 'Never create a key')
      expect(notes_prompt).to include('Vietnamese', 'Do not store passwords')
    end
  end
end
