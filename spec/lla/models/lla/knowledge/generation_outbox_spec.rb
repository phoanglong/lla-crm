require 'rails_helper'

RSpec.describe Lla::Knowledge::GenerationOutbox do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('operation'),
      request_digest: Digest::SHA256.hexdigest('request')
    )
  end

  it 'encrypts the dispatch payload and stores a separate integrity digest' do
    outbox = described_class.new(
      operation: operation,
      account: account,
      portal: portal,
      event_type: 'plan_generation',
      idempotency_digest: Digest::SHA256.hexdigest('dispatch'),
      available_at: Time.current
    )
    outbox.payload = { website_url: 'https://docs.example.com/' }
    outbox.save!

    raw_value = described_class.connection.select_value(
      "SELECT payload_ciphertext FROM lla_knowledge_generation_outboxes WHERE id = #{outbox.id}"
    )

    expect(raw_value).not_to include('docs.example.com')
    expect(outbox.reload.payload).to eq(website_url: 'https://docs.example.com/')
    expect(outbox.payload_digest).to eq(Lla::Knowledge::PayloadCipher.digest(website_url: 'https://docs.example.com/'))
  end

  it 'rejects an outbox attached to another tenant operation' do
    other_account = create(:account)
    other_operation = Lla::Knowledge::GenerationOperation.create!(
      account: other_account,
      portal: create(:portal, account: other_account),
      user: create(:user, account: other_account),
      idempotency_digest: Digest::SHA256.hexdigest('other-operation'),
      request_digest: Digest::SHA256.hexdigest('other-request')
    )
    outbox = described_class.new(
      operation: other_operation,
      account: account,
      portal: portal,
      event_type: 'plan_generation',
      idempotency_digest: Digest::SHA256.hexdigest('dispatch'),
      available_at: Time.current
    )
    outbox.payload = {}

    expect(outbox).not_to be_valid
    expect(outbox.errors[:operation]).to include('must share the outbox tenant and portal')
  end
end
