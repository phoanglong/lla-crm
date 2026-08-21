require 'rails_helper'

RSpec.describe Lla::Knowledge::GenerationRetentionCleanupJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('retention-operation'),
      request_digest: Digest::SHA256.hexdigest('retention-request'),
      provider_consent_digests: { 'direct_fetch' => Digest::SHA256.hexdigest('consent') }
    )
  end

  it 'deletes an expired terminal operation and its encrypted outboxes' do
    outbox = operation.outboxes.create!(
      account: account,
      portal: portal,
      event_type: 'plan_generation',
      idempotency_digest: Digest::SHA256.hexdigest('retention-outbox'),
      available_at: Time.current,
      payload: { website_url: portal.homepage_link }
    )
    operation.update_columns(state: 'failed', completed_at: Time.current, expires_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations

    described_class.perform_now

    expect(Lla::Knowledge::GenerationOperation.where(id: operation.id)).to be_empty
    expect(Lla::Knowledge::GenerationOutbox.where(id: outbox.id)).to be_empty
  end

  it 'fails expired active work, purges raw intents and retains a short status tombstone' do
    Lla::Knowledge::GenerationStateService.new(operation).plan!(
      allowed_urls: ['https://docs.example.com/start'],
      categories: [{ name: 'Start' }],
      articles: [{ title: 'Begin', category_name: 'Start', urls: ['https://docs.example.com/start'] }]
    )
    operation.update_columns(expires_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations

    described_class.perform_now

    expect(operation.reload).to have_attributes(
      state: 'failed', last_error_code: 'retention_expired', provider_consent_digests: {}
    )
    expect(operation.expires_at).to be_within(2.seconds).of(described_class::FAILURE_VISIBILITY_PERIOD.from_now)
    expect(operation.outboxes).to be_empty
    expect(operation.items.sole.reload.state).to eq('cancelled')
  end
end
