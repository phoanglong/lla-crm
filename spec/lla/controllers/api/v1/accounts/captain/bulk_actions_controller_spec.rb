require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::BulkActions', type: :request do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:operation_id) { SecureRandom.uuid }
  let!(:responses) { create_list(:captain_assistant_response, 2, assistant: assistant, account: account) }
  let!(:documents) { create_list(:captain_document, 2, assistant: assistant, account: account, status: :available) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def post_bulk(user:, type:, action:, ids:, operation: operation_id)
    post "/api/v1/accounts/#{account.id}/captain/bulk_actions",
         params: { type: type, ids: ids, operation_id: operation, fields: { status: action } },
         headers: user.create_new_auth_token,
         as: :json
  end

  it 'deletes responses atomically and returns explicit outcomes' do
    expect do
      post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: responses.map(&:id))
    end.to change(Captain::AssistantResponse, :count).by(-2)

    expect(response).to have_http_status(:ok)
    expect(json_response).to include(
      success: true,
      requested_count: 2,
      processed_count: 2,
      error_count: 0,
      ids: responses.map(&:id)
    )
    expect(json_response[:outcomes]).to all(include(status: 'deleted'))
  end

  it 'replays a completed operation without executing it twice' do
    post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: responses.map(&:id))
    first_result = json_response

    expect do
      post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: responses.map(&:id))
    end.not_to change(Captain::AssistantResponse, :count)

    expect(response).to have_http_status(:ok)
    expect(json_response).to eq(first_result)
    expect(Lla::Captain::BulkOperation.count).to eq(1)
  end

  it 'rejects reuse of an operation id for a different request' do
    post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: [responses.first.id])
    post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: [responses.second.id])

    expect(response).to have_http_status(:conflict)
    expect(json_response[:success]).to be(false)
  end

  it 'does not reveal or mutate cross-account ids' do
    other_account = create(:account)
    other_assistant = create(:captain_assistant, account: other_account)
    other_response = create(:captain_assistant_response, account: other_account, assistant: other_assistant)

    post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: [other_response.id])

    expect(response).to have_http_status(:ok)
    expect(json_response[:outcomes]).to eq([{ id: other_response.id, status: 'not_found' }])
    expect(other_response.reload).to be_present
  end

  it 'bounds the batch size before querying records' do
    post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: (1..101).to_a)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response[:error]).to include('Batch exceeds 100')
  end

  it 'rejects a mixed batch instead of silently dropping invalid ids' do
    post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: [responses.first.id, 'invalid', -1])

    expect(response).to have_http_status(:unprocessable_content)
    expect(responses.first.reload).to be_present
  end

  it 'requires an idempotency operation id and an allowlisted action' do
    post_bulk(user: admin, type: 'AssistantResponse', action: 'approve', ids: [responses.first.id], operation: nil)

    expect(response).to have_http_status(:unprocessable_content)
    expect(responses.first.reload).to be_approved
  end

  it 'rolls back response deletion when one record fails' do
    failing_id = responses.second.id
    rejecting_callback = proc { throw(:abort) if id == failing_id }
    Captain::AssistantResponse.set_callback(:destroy, :before, rejecting_callback)

    begin
      expect do
        post_bulk(user: admin, type: 'AssistantResponse', action: 'delete', ids: responses.map(&:id))
      end.not_to change(Captain::AssistantResponse, :count)
    ensure
      Captain::AssistantResponse.skip_callback(:destroy, :before, rejecting_callback)
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(Lla::Captain::BulkOperation.last.state).to eq('failed')
  end

  it 'deletes account-owned documents with explicit outcomes' do
    expect do
      post_bulk(user: admin, type: 'AssistantDocument', action: 'delete', ids: documents.map(&:id))
    end.to change(Captain::Document, :count).by(-2)

    expect(response).to have_http_status(:ok)
    expect(json_response[:processed_count]).to eq(2)
  end

  it 'claims and queues each syncable document with an opaque token' do
    clear_enqueued_jobs

    expect do
      post_bulk(user: admin, type: 'AssistantDocument', action: 'sync', ids: documents.map(&:id))
    end.to have_enqueued_job(Captain::Documents::PerformSyncJob).exactly(2).times

    expect(response).to have_http_status(:ok)
    expect(json_response[:ids]).to eq(documents.map(&:id))
    documents.each do |document|
      expect(document.reload).to have_attributes(sync_status: 'pending')
      expect(document.sync_claim_digest).to match(/\A[0-9a-f]{64}\z/)
      expect(document.sync_claimed_at).to be_present
    end
    expect(enqueued_jobs.pluck(:args).flatten.grep(String)).not_to include(*documents.map(&:sync_claim_digest))
  end

  it 'does not queue an active document claim under a different operation' do
    post_bulk(user: admin, type: 'AssistantDocument', action: 'sync', ids: [documents.first.id])
    clear_enqueued_jobs

    post_bulk(
      user: admin,
      type: 'AssistantDocument',
      action: 'sync',
      ids: [documents.first.id],
      operation: SecureRandom.uuid
    )

    expect(response).to have_http_status(:ok)
    expect(json_response[:outcomes]).to eq([{ id: documents.first.id, status: 'already_claimed' }])
    expect(enqueued_jobs).to be_empty
  end

  it 'returns per-item failure and releases the claim when enqueueing fails' do
    allow(Captain::Documents::PerformSyncJob).to receive(:perform_later).and_return(nil)

    post_bulk(user: admin, type: 'AssistantDocument', action: 'sync', ids: [documents.first.id])

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response[:outcomes]).to eq([{ id: documents.first.id, status: 'enqueue_failed' }])
    expect(documents.first.reload).to have_attributes(
      sync_status: 'failed',
      sync_claim_digest: nil,
      sync_claimed_at: nil,
      last_sync_error_code: 'enqueue_failed'
    )
  end

  it 'skips PDF and unavailable documents without enqueueing' do
    pdf = build(:captain_document, assistant: assistant, account: account, status: :available)
    pdf.pdf_file.attach(io: StringIO.new('PDF'), filename: 'test.pdf', content_type: 'application/pdf')
    pdf.save!
    in_progress = create(:captain_document, assistant: assistant, account: account, status: :in_progress)
    admin
    clear_enqueued_jobs

    post_bulk(user: admin, type: 'AssistantDocument', action: 'sync', ids: [pdf.id, in_progress.id])

    expect(response).to have_http_status(:ok)
    expect(json_response[:outcomes]).to contain_exactly(
      { id: pdf.id, status: 'not_syncable' },
      { id: in_progress.id, status: 'not_available' }
    )
    expect(enqueued_jobs).to be_empty
  end

  it 'denies non-administrators' do
    post_bulk(user: agent, type: 'AssistantResponse', action: 'delete', ids: [responses.first.id])

    expect(response).to have_http_status(:unauthorized)
  end

  it 'loads the controller and execution service from the LLA-owned tree' do
    expect(Api::V1::Accounts::Captain::BulkActionsController.instance_method(:create).source_location.first)
      .to include('/lla/rails/')
    expect(Lla::Captain::BulkActionService.instance_method(:perform).source_location.first).to include('/lla/rails/')
  end
end
