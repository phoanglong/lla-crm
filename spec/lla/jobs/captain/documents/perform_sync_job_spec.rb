require 'rails_helper'

RSpec.describe Captain::Documents::PerformSyncJob, type: :job do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, assistant: assistant, account: account, status: :available) }

  def stub_lock(job)
    allow(job).to receive(:with_lock).and_yield
  end

  def stub_page_fetch(content: 'Updated content')
    fetch_result = Captain::Documents::SinglePageFetcher::Result.new(
      success: true,
      title: 'Updated title',
      content: content
    )
    fetcher = instance_double(Captain::Documents::SinglePageFetcher, fetch: fetch_result)
    allow(Captain::Documents::SinglePageFetcher).to receive(:new).and_return(fetcher)
  end

  def stub_page_fetch_failure
    fetcher = instance_double(Captain::Documents::SinglePageFetcher)
    allow(fetcher).to receive(:fetch).and_raise(StandardError, 'boom')
    allow(Captain::Documents::SinglePageFetcher).to receive(:new).and_return(fetcher)
  end

  it 'syncs the document content' do
    travel_to Time.zone.local(2026, 5, 18, 10, 0, 0) do
      job = described_class.new
      stub_lock(job)
      stub_page_fetch

      job.perform(document)

      expect(document.reload).to have_attributes(
        sync_status: 'synced',
        last_sync_attempted_at: Time.current,
        last_synced_at: Time.current,
        content: 'Updated content'
      )
    end
  end

  it 'marks unexpected failures as failed' do
    travel_to Time.zone.local(2026, 5, 18, 10, 0, 0) do
      job = described_class.new
      stub_lock(job)
      stub_page_fetch_failure

      expect { job.perform(document) }.to raise_error(StandardError, 'boom')

      expect(document.reload).to have_attributes(
        sync_status: 'failed',
        last_sync_error_code: 'sync_error',
        last_sync_attempted_at: Time.current
      )
    end
  end

  it 'ignores a job whose opaque claim token does not own the document claim' do
    token = SecureRandom.hex(32)
    document.update!(
      sync_status: :pending,
      sync_claim_digest: Digest::SHA256.hexdigest("#{account.id}\0#{document.id}\0#{token}"),
      sync_claimed_at: Time.current
    )
    job = described_class.new
    expect(Captain::Documents::SinglePageFetcher).not_to receive(:new)

    job.perform(document, 'wrong-token')

    expect(document.reload).to have_attributes(
      sync_status: 'pending',
      sync_claim_digest: Digest::SHA256.hexdigest("#{account.id}\0#{document.id}\0#{token}")
    )
  end

  it 'syncs and clears only the claim owned by the queued token' do
    token = SecureRandom.hex(32)
    document.update!(
      sync_status: :pending,
      sync_claim_digest: Digest::SHA256.hexdigest("#{account.id}\0#{document.id}\0#{token}"),
      sync_claimed_at: Time.current
    )
    job = described_class.new
    stub_lock(job)
    stub_page_fetch(content: 'Claimed content')

    job.perform(document, token)

    expect(document.reload).to have_attributes(
      sync_status: 'synced',
      content: 'Claimed content',
      sync_claim_digest: nil,
      sync_claimed_at: nil
    )
  end

  it 'preserves the owned claim and retries when the distributed lock is busy' do
    token = SecureRandom.hex(32)
    digest = Digest::SHA256.hexdigest("#{account.id}\0#{document.id}\0#{token}")
    document.update!(sync_status: :pending, sync_claim_digest: digest, sync_claimed_at: Time.current)
    allow(Redis::Alfred).to receive(:set).and_return(false)

    expect { described_class.new.perform(document, token) }
      .to raise_error(Captain::Documents::PerformSyncJob::LockUnavailable)
    expect(document.reload).to have_attributes(sync_status: 'pending', sync_claim_digest: digest)
  end
end
