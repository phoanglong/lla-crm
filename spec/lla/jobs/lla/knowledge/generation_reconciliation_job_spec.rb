require 'rails_helper'

RSpec.describe Lla::Knowledge::GenerationReconciliationJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('reconcile-operation'),
      request_digest: Digest::SHA256.hexdigest('reconcile-request')
    )
  end
  let(:plan) do
    {
      allowed_urls: ['https://docs.example.com/start'],
      categories: [{ name: 'Start' }],
      articles: [{ title: 'Begin', category_name: 'Start', urls: ['https://docs.example.com/start'] }]
    }
  end

  before do
    clear_enqueued_jobs
    Lla::Knowledge::GenerationStateService.new(operation).plan!(plan)
  end

  it 'releases stale item claims and requeues a lost writer delivery' do
    item = operation.items.sole
    outbox = operation.outboxes.sole
    Lla::Knowledge::GenerationStateService.new(operation).claim_item!(item.id, token: 'abandoned-worker')
    item.update_columns(claimed_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
    outbox.update_columns(state: 'delivered', attempts: 1, delivered_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations

    described_class.perform_now

    expect(item.reload).to have_attributes(state: 'pending', claim_digest: nil, last_error_code: 'stale_writer_claim')
    expect(outbox.reload).to have_attributes(state: 'pending', claim_digest: nil)
    expect(enqueued_jobs).to include(a_hash_including('job_class' => Lla::Knowledge::GenerationOutboxDispatchJob.name))
  end

  it 'fails an item whose stale worker exhausted its bounded claims' do
    item = operation.items.sole
    item.update_columns( # rubocop:disable Rails/SkipsModelValidations
      state: 'claimed', attempts: operation.max_attempts,
      claim_digest: Digest::SHA256.hexdigest('stale'), claimed_at: 1.hour.ago
    )

    described_class.perform_now

    expect(item.reload).to have_attributes(state: 'failed', last_error_code: 'writer_retry_exhausted')
    expect(operation.reload).to have_attributes(state: 'completed_with_errors', finished_items: 1, failed_items: 1)
  end

  it 'recovers a translation claim using its own outbox and redacted error family' do
    item = operation.items.sole
    outbox = operation.outboxes.sole
    operation.update!(operation_type: 'translation')
    item.update!(item_type: 'translation')
    outbox.update!(event_type: 'translate_article', payload: { generation_item_id: item.id })
    Lla::Knowledge::GenerationStateService.new(operation).claim_item!(item.id, token: 'abandoned-translation')
    item.update_columns(claimed_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
    outbox.update_columns(state: 'delivered', attempts: 1, delivered_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations

    described_class.perform_now

    expect(item.reload).to have_attributes(state: 'pending', claim_digest: nil, last_error_code: 'stale_translation_claim')
    expect(outbox.reload).to have_attributes(state: 'pending', claim_digest: nil)
  end

  it 'repairs a stale dispatcher claim without leaking or replacing its payload' do
    outbox = operation.outboxes.sole
    original_digest = outbox.payload_digest
    outbox.update_columns( # rubocop:disable Rails/SkipsModelValidations
      state: 'claimed', attempts: 1,
      claim_digest: Digest::SHA256.hexdigest('dispatcher'), claimed_at: 1.hour.ago
    )

    described_class.perform_now

    expect(outbox.reload).to have_attributes(
      state: 'failed', claim_digest: nil, last_error_code: 'stale_dispatch_claim', payload_digest: original_digest
    )
  end

  it 'settles durable counters from item truth after an interrupted final update' do
    item = operation.items.sole
    item.update_columns(state: 'failed', last_error_code: 'worker_failed', completed_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

    described_class.perform_now

    expect(operation.reload).to have_attributes(
      state: 'completed_with_errors', expected_items: 1, finished_items: 1, failed_items: 1
    )
  end

  it 'fails closed instead of reporting clean completion when a planned item is missing' do
    operation.items.delete_all

    described_class.perform_now

    expect(operation.reload).to have_attributes(
      state: 'failed', expected_items: 1, finished_items: 0,
      failed_items: 0, last_error_code: 'knowledge_item_count_mismatch'
    )
  end
end
