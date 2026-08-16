require 'rails_helper'

RSpec.describe Captain::FaqObservation, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:suggestion) do
    assistant.faq_suggestions.create!(question: 'How do I reset my password?', answer: 'Use the reset link.')
  end

  def build_observation(conversation)
    described_class.new(
      faq_suggestion: suggestion,
      conversation: conversation,
      generated_question: suggestion.question,
      generated_answer: suggestion.answer
    )
  end

  it 'derives the account when the conversation and suggestion share a tenant' do
    observation = build_observation(create(:conversation, account: account))

    expect(observation).to be_valid
    expect(observation.account).to eq(account)
  end

  it 'rejects a conversation from another tenant' do
    observation = build_observation(create(:conversation, account: create(:account)))

    expect(observation).not_to be_valid
    expect(observation.errors[:conversation]).to include('must belong to the same account as the FAQ suggestion')
    expect(observation.account).to eq(account)
  end

  it 'assigns a stable normalized source fingerprint' do
    conversation = create(:conversation, account: account)
    first = build_observation(conversation)
    equivalent = described_class.new(
      faq_suggestion: suggestion,
      conversation: conversation,
      generated_question: "  HOW do I reset my\npassword? ",
      generated_answer: ' USE the reset link. '
    )

    first.validate
    equivalent.validate

    expect(equivalent.source_fingerprint).to eq(first.source_fingerprint)
  end

  it 'enforces source idempotency across suggestions at the database boundary' do
    conversation = create(:conversation, account: account)
    build_observation(conversation).save!
    other_suggestion = assistant.faq_suggestions.create!(question: 'Where is account recovery?', answer: 'Open your profile.')

    expect do
      described_class.create!(
        faq_suggestion: other_suggestion,
        conversation: conversation,
        generated_question: 'How do I reset my password?',
        generated_answer: 'Use the reset link.'
      )
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
