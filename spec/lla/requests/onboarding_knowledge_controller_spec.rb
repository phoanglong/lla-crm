require 'rails_helper'

RSpec.describe 'LLA onboarding knowledge API', type: :request do
  let(:account) { create(:account, domain: 'example.com') }
  let(:admin) { create(:user, account: account, role: :administrator) }

  around do |example|
    with_modified_env('LLA_ONBOARDING_WORKSPACE_ENABLED' => 'true') { example.run }
  end

  before do
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(false)
  end

  it 'enables the inbox workspace and invokes the LLA help-center service off cloud' do
    account.update!(custom_attributes: { 'onboarding_step' => 'account_details' })
    widget_service = instance_double(Onboarding::WebWidgetCreationService, perform: nil)
    help_center_service = instance_double(Onboarding::HelpCenterCreationService, perform: nil)
    allow(Onboarding::WebWidgetCreationService).to receive(:new).and_return(widget_service)
    allow(Onboarding::HelpCenterCreationService).to receive(:new).and_return(help_center_service)

    patch "/api/v1/accounts/#{account.id}/onboarding",
          params: { website: 'https://docs.example.com', onboarding_step: 'account_details' },
          headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    expect(account.reload.custom_attributes['onboarding_step']).to eq('inbox_setup')
    expect(widget_service).to have_received(:perform)
    expect(help_center_service).to have_received(:perform)
  end

  it 'returns durable operation state and tenant-scoped portal counts' do
    portal = create(:portal, account: account)
    category = create(:category, portal: portal, account: account)
    create(:article, portal: portal, category: category, account: account, author_id: admin.id)
    operation = create_operation(account: account, portal: portal, user: admin, state: 'running', expected_items: 3, finished_items: 1)
    account.update!(custom_attributes: { 'lla_knowledge_generation_operation_id' => operation.id })

    get "/api/v1/accounts/#{account.id}/onboarding/help_center_generation",
        headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).to include(
      'generation_id' => operation.id,
      'articles_count' => 1,
      'categories_count' => 1,
      'state' => include('status' => 'generating', 'total' => 3, 'finished' => 1, 'errors' => 0)
    )
  end

  it 'does not expose an operation referenced from another tenant' do
    other_account = create(:account)
    other_user = create(:user, account: other_account, role: :administrator)
    other_operation = create_operation(account: other_account, portal: create(:portal, account: other_account), user: other_user)
    account.update!(custom_attributes: { 'lla_knowledge_generation_operation_id' => other_operation.id })

    get "/api/v1/accounts/#{account.id}/onboarding/help_center_generation",
        headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).to eq(
      'generation_id' => nil,
      'state' => nil,
      'articles_count' => 0,
      'categories_count' => 0
    )
  end

  it 'cancels only the durable operation owned by the current account' do
    portal = create(:portal, account: account)
    operation = create_operation(account: account, portal: portal, user: admin, state: 'running')
    account.update!(custom_attributes: { 'lla_knowledge_generation_operation_id' => operation.id })

    delete "/api/v1/accounts/#{account.id}/onboarding/help_center_generation",
           headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body.dig('state', 'status')).to eq('cancelled')
    expect(operation.reload).to have_attributes(state: 'cancelled', last_error_code: 'cancelled_by_user')
  end

  it 'returns an indistinguishable miss and cannot cancel another tenant operation' do
    other_account = create(:account)
    other_user = create(:user, account: other_account, role: :administrator)
    other_operation = create_operation(
      account: other_account, portal: create(:portal, account: other_account), user: other_user
    )
    account.update!(custom_attributes: { 'lla_knowledge_generation_operation_id' => other_operation.id })

    delete "/api/v1/accounts/#{account.id}/onboarding/help_center_generation",
           headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:not_found)
    expect(other_operation.reload.state).to eq('pending')
  end

  it 'clears the operation pointer only while completing the current inbox step' do
    account.update!(custom_attributes: {
                      'onboarding_step' => 'inbox_setup',
                      'lla_knowledge_generation_operation_id' => 123
                    })

    patch "/api/v1/accounts/#{account.id}/onboarding",
          params: { onboarding_step: 'inbox_setup' },
          headers: admin.create_new_auth_token, as: :json

    expect(account.reload.custom_attributes).not_to have_key('lla_knowledge_generation_operation_id')

    account.update!(custom_attributes: {
                      'onboarding_step' => 'account_details',
                      'lla_knowledge_generation_operation_id' => 456
                    })
    patch "/api/v1/accounts/#{account.id}/onboarding",
          params: { onboarding_step: 'inbox_setup' },
          headers: admin.create_new_auth_token, as: :json

    expect(account.reload.custom_attributes['lla_knowledge_generation_operation_id']).to eq(456)
  end

  def create_operation(account:, portal:, user:, **attributes)
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      operation_type: 'onboarding',
      idempotency_digest: Digest::SHA256.hexdigest("idempotency-#{account.id}"),
      request_digest: Digest::SHA256.hexdigest("request-#{account.id}"),
      **attributes
    )
  end
end
