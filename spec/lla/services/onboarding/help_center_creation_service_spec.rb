require 'rails_helper'

RSpec.describe Onboarding::HelpCenterCreationService do
  let(:account) { create(:account, custom_attributes: { 'website' => 'https://docs.example.com' }) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:service) { described_class.new(account, admin) }

  before { clear_enqueued_jobs }

  it 'persists and reuses the fallback portal when provider egress is denied' do
    first_portal = nil

    expect { first_portal = service.perform }
      .to change(account.portals, :count).by(1)
      .and not_change(Lla::Knowledge::GenerationOperation, :count)
      .and not_change(Lla::Knowledge::GenerationOutbox, :count)

    replay = described_class.new(account.reload, admin).perform

    expect(replay.id).to eq(first_portal.id)
    expect(account.portals.count).to eq(1)
    expect(first_portal.reload.lla_onboarding_key_digest).to match(/\A[0-9a-f]{64}\z/)
  end

  it 'atomically creates and reuses one consent-bound operation and pointer' do
    grant_direct_fetch_consent

    with_provider_egress do
      portal = service.perform
      operation = Lla::Knowledge::GenerationOperation.sole

      account.update!(custom_attributes: account.reload.custom_attributes.merge('website' => 'https://changed.example.com'))
      replay = described_class.new(account, admin).perform

      expect(replay.id).to eq(portal.id)
      expect(Lla::Knowledge::GenerationOperation.count).to eq(1)
      expect(Lla::Knowledge::GenerationOutbox.count).to eq(1)
      expect(account.reload.custom_attributes['lla_knowledge_generation_operation_id']).to eq(operation.id)
      expect(operation.outboxes.sole.payload).to include(website_url: 'https://docs.example.com/')
      expect(enqueued_jobs).to include(
        a_hash_including('job_class' => Lla::Knowledge::GenerationOutboxDispatchJob.name,
                         'arguments' => [operation.id])
      )
    end
  end

  it 'claims an existing legacy portal instead of creating a duplicate' do
    legacy_portal = create(:portal, account: account)

    expect(service.perform.id).to eq(legacy_portal.id)
    expect(account.portals.count).to eq(1)
    expect(legacy_portal.reload.lla_onboarding_key_digest).to match(/\A[0-9a-f]{64}\z/)
  end

  it 'never downloads a cross-origin logo even when direct fetch is permitted' do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'brand_info' => { 'logos' => [{ 'url' => 'https://attacker.example/logo.png' }] }
    ))
    grant_direct_fetch_consent
    expect(SafeFetch).not_to receive(:fetch)

    with_provider_egress { service.perform }
  end

  private

  def grant_direct_fetch_consent
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'direct_fetch' => { 'enabled' => true, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
      }
    ))
  end

  def with_provider_egress(&)
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_WEBSITE_ANALYSIS_ENABLED' => 'true',
      &
    )
  end
end
