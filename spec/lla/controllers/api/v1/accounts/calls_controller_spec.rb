require 'rails_helper'

RSpec.describe 'Calls API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, :with_phone_number, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let!(:agent_call) do
    create(:call, account: account, inbox: inbox, conversation: conversation, contact: contact,
                  accepted_by_agent: agent, status: 'completed', transcript: 'synthetic transcript')
  end
  let!(:other_call) do
    create(:call, account: account, inbox: inbox, conversation: conversation,
                  contact: contact, accepted_by_agent: admin)
  end

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, user: agent, inbox: inbox)
  end

  it 'returns 401 when unauthenticated' do
    get "/api/v1/accounts/#{account.id}/calls"

    expect(response).to have_http_status(:unauthorized)
  end

  it 'fails closed when the account capability is disabled' do
    account.disable_features!('channel_voice')

    get "/api/v1/accounts/#{account.id}/calls", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:forbidden), response.body
  end

  it 'returns sensitive fields only to an administrator' do
    get "/api/v1/accounts/#{account.id}/calls", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok), response.body
    payload = response.parsed_body['payload']
    expect(payload.map { |call| call['id'] }).to contain_exactly(agent_call.id, other_call.id)
    item = payload.find { |call| call['id'] == agent_call.id }
    expect(item['transcript']).to eq('synthetic transcript')
    expect(item['contact']['phone_number']).to eq(contact.phone_number)
    expect(item['call_id']).to eq(agent_call.provider_call_id)
  end

  it 'redacts phone, transcript, media URL and provider ID from report managers' do
    report_manager = create(:user, account: account, role: :agent)
    role = create(:custom_role, account: account, permissions: ['report_manage'])
    account.account_users.find_by(user_id: report_manager.id).update!(custom_role: role)

    get "/api/v1/accounts/#{account.id}/calls", headers: report_manager.create_new_auth_token

    item = response.parsed_body['payload'].find { |call| call['id'] == agent_call.id }
    expect(item).not_to include('call_id', 'transcript', 'recording_url')
    expect(item['contact']).not_to include('phone_number')
    expect(item).to include('has_transcript' => true, 'has_recording' => false)
  end

  it 'scopes a regular agent to calls they accepted and redacts sensitive fields' do
    get "/api/v1/accounts/#{account.id}/calls", headers: agent.create_new_auth_token

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body['payload'].map { |call| call['id'] }).to contain_exactly(agent_call.id)
    expect(response.parsed_body['payload'].first).not_to include('transcript', 'call_id')
  end

  it 'rejects an unbounded or invalid list query' do
    get "/api/v1/accounts/#{account.id}/calls",
        params: { since: 100.days.ago.to_i, until: Time.current.to_i },
        headers: admin.create_new_auth_token

    expect(response).to have_http_status(:bad_request), response.body
  end

  it 'loads the controller and views from LLA in pure mode' do
    expect(Api::V1::Accounts::CallsController.instance_method(:index).source_location.first).to include('/lla/rails/')
    expect(Api::V1::Accounts::CallsController.view_paths.map(&:to_path).first).to include('/lla/rails/app/views')
  end
end
