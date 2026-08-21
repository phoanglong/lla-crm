require 'rails_helper'

RSpec.describe Onboarding::HelpCenterArticleGenerationJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('planning-operation'),
      request_digest: Digest::SHA256.hexdigest('planning-request')
    )
  end
  let(:plan) do
    {
      'allowed_urls' => ['https://docs.example.com/start'],
      'categories' => [{ 'name' => 'Start', 'description' => 'Setup' }],
      'articles' => [{ 'title' => 'Begin', 'category_name' => 'Start', 'urls' => ['https://docs.example.com/start'] }]
    }
  end

  before do
    clear_enqueued_jobs
    allow(Onboarding::HelpCenterCurator).to receive(:new).with(account: account, operation: operation)
                                                         .and_return(instance_double(Onboarding::HelpCenterCurator, perform: plan))
  end

  it 'plans durable writer intents and schedules their dispatcher' do
    expect { described_class.perform_now(operation.id) }
      .to change(operation.items, :count).by(1)
      .and change(operation.outboxes, :count).by(1)
      .and have_enqueued_job(Lla::Knowledge::GenerationOutboxDispatchJob).with(operation.id)

    expect(operation.reload).to have_attributes(state: 'dispatching', expected_items: 1, claim_digest: nil)
  end

  it 'is idempotent after the plan has committed' do
    described_class.perform_now(operation.id)

    expect { described_class.perform_now(operation.id) }
      .to not_change(operation.items, :count)
      .and not_change(operation.outboxes, :count)
  end

  it 'records a fail-closed skip when provider policy denies curation' do
    allow(Onboarding::HelpCenterCurator).to receive(:new).and_raise(Lla::Knowledge::ProviderPolicy::Denied)

    described_class.perform_now(operation.id)

    expect(operation.reload).to have_attributes(state: 'skipped', last_error_code: 'provider_disabled')
  end
end
