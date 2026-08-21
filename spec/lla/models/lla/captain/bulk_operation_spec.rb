require 'rails_helper'

RSpec.describe Lla::Captain::BulkOperation, type: :model do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  it 'sets a finite expiry for a valid digest-only operation' do
    freeze_time do
      operation = build_operation

      expect(operation).to be_valid
      expect(operation.expires_at).to eq(described_class::RETENTION_PERIOD.from_now)
    end
  end

  it 'rejects malformed digests and inconsistent counts before persistence' do
    operation = build_operation(
      key_digest: 'raw-operation-id',
      requested_count: 1,
      processed_count: 1,
      error_count: 1
    )

    expect(operation).not_to be_valid
    expect(operation.errors).to have_key(:key_digest)
    expect(operation.errors[:base]).to include('operation counts are inconsistent')
  end

  it 'loads from the LLA-owned tree' do
    expect(described_class.instance_method(:consistent_counts).source_location.first).to include('/lla/rails/')
  end

  private

  def build_operation(**attributes)
    described_class.new(
      {
        account: account,
        user: user,
        key_digest: Digest::SHA256.hexdigest('operation'),
        request_digest: Digest::SHA256.hexdigest('request'),
        resource_type: 'AssistantResponse',
        action: 'delete',
        requested_count: 1
      }.merge(attributes)
    )
  end
end
