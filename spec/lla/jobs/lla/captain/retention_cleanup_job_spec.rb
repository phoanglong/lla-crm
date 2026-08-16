require 'rails_helper'

RSpec.describe Lla::Captain::RetentionCleanupJob, type: :job do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
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

  it 'purges expired feedback and idempotency records while retaining live records' do
    expired_report = create(:captain_message_report, message: message, user: user)
    live_report = create(:captain_message_report)
    expired_report.update_column(:expires_at, 1.second.ago) # rubocop:disable Rails/SkipsModelValidations

    expired_operation = create_operation('expired', expires_at: 1.second.ago)
    live_operation = create_operation('live', expires_at: 1.day.from_now)

    described_class.perform_now

    aggregate_failures do
      expect(Captain::MessageReport.exists?(expired_report.id)).to be(false)
      expect(Captain::MessageReport.exists?(live_report.id)).to be(true)
      expect(Lla::Captain::BulkOperation.exists?(expired_operation.id)).to be(false)
      expect(Lla::Captain::BulkOperation.exists?(live_operation.id)).to be(true)
    end
  end

  private

  def create_operation(key, expires_at:)
    Lla::Captain::BulkOperation.create!(
      account: account,
      user: user,
      key_digest: Digest::SHA256.hexdigest(key),
      request_digest: Digest::SHA256.hexdigest("request-#{key}"),
      resource_type: 'AssistantResponse',
      action: 'delete',
      requested_count: 1,
      expires_at: expires_at
    )
  end
end
