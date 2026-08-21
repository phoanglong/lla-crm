require 'rails_helper'

RSpec.describe Captain::MessageReport, type: :model do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user, account: account) }
  let(:message) do
    create(
      :message,
      account: account,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: false
    )
  end

  it 'derives and overwrites account and conversation from the message' do
    other_account = create(:account)
    report = described_class.create!(
      message: message,
      user: user,
      account: other_account,
      conversation: create(:conversation, account: other_account),
      report_reason: 'other'
    )

    expect(report).to have_attributes(account_id: account.id, conversation_id: conversation.id)
  end

  it 'accepts only public outgoing Captain assistant messages' do
    incoming = create(:message, account: account, conversation: conversation, message_type: :incoming)
    private_reply = create(
      :message,
      account: account,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: true
    )

    expect(build_report(incoming)).not_to be_valid
    expect(build_report(private_reply)).not_to be_valid
  end

  it 'requires the reporting user to belong to the message account' do
    outsider = create(:user, account: create(:account))

    expect(build_report(message, user: outsider)).not_to be_valid
  end

  it 'sanitizes markup and redacts common PII and secret patterns' do
    report = build_report(
      message,
      description: '<b>Email me at person@example.com or +61 412 345 678</b> Bearer abcdefghijklmnopqrstuvwxyz'
    )

    expect(report).to be_valid
    expect(report.description).to eq(
      'Email me at [REDACTED_EMAIL] or [REDACTED_PHONE] [REDACTED_SECRET]'
    )
  end

  it 'rejects oversized direct model input and bounds persisted descriptions' do
    report = build_report(message, description: 'x' * (described_class::MAX_DESCRIPTION_INPUT_BYTES + 1))

    expect(report).not_to be_valid
    expect(report.errors[:description]).to include('is too large')
  end

  it 'sets a finite retention expiry' do
    freeze_time do
      report = build_report(message)

      expect(report).to be_valid
      expect(report.expires_at).to eq(described_class::RETENTION_PERIOD.from_now)
    end
  end

  it 'enforces one effective report per account, user and message at the database boundary' do
    described_class.create!(message: message, user: user, report_reason: 'other')
    duplicate = described_class.new(message: message, user: user, report_reason: 'incorrect_information')

    expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'rejects cross-tenant direct SQL writes at the database boundary' do
    other_account = create(:account)
    other_user = create(:user, account: other_account)

    expect do
      described_class.insert_all!([ # rubocop:disable Rails/SkipsModelValidations
                                    {
                                      account_id: other_account.id,
                                      conversation_id: conversation.id,
                                      message_id: message.id,
                                      user_id: other_user.id,
                                      report_reason: 'other',
                                      expires_at: 1.day.from_now,
                                      created_at: Time.current,
                                      updated_at: Time.current
                                    }
                                  ]) # rubocop:enable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it 'loads from the LLA-owned tree' do
    expect(described_class.instance_method(:message_contract).source_location.first).to include('/lla/rails/')
  end

  private

  def build_report(report_message, user: self.user, description: nil)
    described_class.new(
      message: report_message,
      user: user,
      report_reason: 'other',
      description: description
    )
  end
end
