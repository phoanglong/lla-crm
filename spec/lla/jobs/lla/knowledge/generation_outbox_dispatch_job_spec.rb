require 'rails_helper'

RSpec.describe Lla::Knowledge::GenerationOutboxDispatchJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('dispatch-operation'),
      request_digest: Digest::SHA256.hexdigest('dispatch-request')
    )
  end
  let!(:outbox) do
    operation.outboxes.create!(
      account: account,
      portal: portal,
      event_type: 'plan_generation',
      idempotency_digest: Digest::SHA256.hexdigest('dispatch-outbox'),
      available_at: Time.current,
      payload: { website_url: 'https://docs.example.com/' }
    )
  end

  before { clear_enqueued_jobs }

  it 'claims, enqueues and durably acknowledges a ready intent' do
    expect { described_class.perform_now(operation.id) }
      .to have_enqueued_job(Onboarding::HelpCenterArticleGenerationJob).with(operation.id).on_queue('low')

    expect(outbox.reload).to have_attributes(state: 'delivered', attempts: 1, claim_digest: nil)
    expect(outbox.delivered_at).to be_present
  end

  it 'does not enqueue an already delivered intent twice' do
    described_class.perform_now(operation.id)
    clear_enqueued_jobs

    expect { described_class.perform_now(operation.id) }
      .not_to have_enqueued_job(Onboarding::HelpCenterArticleGenerationJob)
  end

  it 'dispatches translation intents to the durable translation worker' do
    outbox.update!(event_type: 'translate_article', payload: { generation_item_id: 123 })

    expect { described_class.perform_now(operation.id) }
      .to have_enqueued_job(Captain::Articles::TranslateJob).with(outbox.id).on_queue('low')
  end

  it 'dispatches reindex intents to the versioned indexing worker' do
    outbox.update!(event_type: 'rebuild_index', payload: { generation_item_id: 123 })

    expect { described_class.perform_now(operation.id) }
      .to have_enqueued_job(Portal::ArticleIndexingJob).with(outbox.id).on_queue('low')
  end

  it 'releases a failed enqueue with a stable redacted code and bounded backoff' do
    allow(Onboarding::HelpCenterArticleGenerationJob).to receive(:perform_later).and_raise('queue unavailable')

    expect { described_class.perform_now(operation.id) }.not_to raise_error

    expect(outbox.reload).to have_attributes(
      state: 'failed', attempts: 1, claim_digest: nil, last_error_code: 'dispatch_runtime_error'
    )
    expect(outbox.available_at).to be > Time.current
  end
end
