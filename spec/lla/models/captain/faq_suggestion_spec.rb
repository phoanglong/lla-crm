require 'rails_helper'

RSpec.describe Captain::FaqSuggestion, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  it 'assigns the tenant and a stable normalized content fingerprint' do
    first = assistant.faq_suggestions.create!(question: 'How do I enable it?', answer: 'Open Settings.')
    equivalent = assistant.faq_suggestions.build(question: '  HOW do I enable it? ', answer: "Open\nSettings.")

    equivalent.validate

    expect(first.account).to eq(account)
    expect(equivalent.content_fingerprint).to eq(first.content_fingerprint)
  end

  it 'enforces exact content idempotency at the database boundary' do
    assistant.faq_suggestions.create!(question: 'How do I enable it?', answer: 'Open Settings.')

    expect do
      assistant.faq_suggestions.create!(question: ' HOW do I enable it? ', answer: "Open\nSettings.")
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'keeps the uniqueness boundary scoped to an assistant and tenant' do
    assistant.faq_suggestions.create!(question: 'How do I enable it?', answer: 'Open Settings.')
    other = create(:captain_assistant, account: account)

    expect do
      other.faq_suggestions.create!(question: 'How do I enable it?', answer: 'Open Settings.')
    end.to change(described_class, :count).by(1)
  end
end
