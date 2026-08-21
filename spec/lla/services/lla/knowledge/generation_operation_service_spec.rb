require 'rails_helper'

RSpec.describe Lla::Knowledge::GenerationOperationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:payload) { { website_url: 'https://docs.example.com/', locale: 'en' } }
  let(:arguments) do
    {
      account: account,
      portal: portal,
      user: user,
      idempotency_key: 'onboarding:request-123',
      operation_type: :onboarding,
      event_type: :plan_generation,
      payload: payload,
      provider: :direct_fetch,
      capability: :website_analysis
    }
  end

  around do |example|
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'direct_fetch' => { 'enabled' => true, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
      }
    ))
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_WEBSITE_ANALYSIS_ENABLED' => 'true'
    ) { example.run }
  end

  it 'atomically persists one tenant-bound operation and encrypted outbox intent' do
    operation = described_class.new(**arguments).perform

    expect(operation).to have_attributes(account_id: account.id, portal_id: portal.id, user_id: user.id)
    expect(operation.consent_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(operation.outboxes.sole.payload).to eq(payload)
  end

  it 'returns the same operation and outbox for an exact replay' do
    first = described_class.new(**arguments).perform
    reordered_payload = { locale: 'en', website_url: 'https://docs.example.com/' }
    replay = described_class.new(**arguments, payload: reordered_payload).perform

    expect(replay.id).to eq(first.id)
    expect(first.outboxes.count).to eq(1)
  end

  it 'rejects reuse of the idempotency key with a changed request' do
    described_class.new(**arguments).perform

    expect do
      described_class.new(**arguments, payload: payload.merge(locale: 'vi')).perform
    end.to raise_error(described_class::Conflict, 'lla_knowledge_idempotency_conflict')
  end

  it 'creates no operation when consent is absent' do
    account.update!(custom_attributes: account.custom_attributes.except('lla_provider_consents'))

    expect { described_class.new(**arguments).perform }
      .to raise_error(Lla::Knowledge::ProviderPolicy::Denied)
      .and not_change(Lla::Knowledge::GenerationOperation, :count)
      .and not_change(Lla::Knowledge::GenerationOutbox, :count)
  end

  it 'rejects forged cross-tenant portal and user arguments before persistence' do
    other_account = create(:account)
    forged_arguments = arguments.merge(
      portal: create(:portal, account: other_account),
      user: create(:user, account: other_account)
    )

    expect { described_class.new(**forged_arguments).perform }
      .to raise_error(described_class::InvalidRequest)
      .and not_change(Lla::Knowledge::GenerationOperation, :count)
  end
end
