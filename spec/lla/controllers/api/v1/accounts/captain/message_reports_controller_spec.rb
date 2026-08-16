require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::MessageReports', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:message) do
    create(
      :message,
      account: account,
      conversation: conversation,
      message_type: :outgoing,
      sender: assistant,
      private: false
    )
  end

  before do
    account.enable_features!('captain_integration')
    create(:inbox_member, user: agent, inbox: inbox)
  end

  def json_response
    response.parsed_body.deep_symbolize_keys
  end

  def post_report(params: valid_params, user: agent)
    post "/api/v1/accounts/#{account.id}/captain/message_reports",
         params: params,
         headers: user.create_new_auth_token,
         as: :json
  end

  def valid_params
    {
      message_id: message.id,
      report_reason: 'incorrect_information',
      description: 'The generated citation is wrong.'
    }
  end

  it 'requires authentication' do
    post "/api/v1/accounts/#{account.id}/captain/message_reports", params: valid_params, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'works for a self-hosted LLA installation without a cloud dependency' do
    InstallationConfig.where(name: 'DEPLOYMENT_ENV').first_or_initialize.update!(value: 'self_hosted')

    expect { post_report }.to change(Captain::MessageReport, :count).by(1)

    expect(response).to have_http_status(:created)
  end

  it 'returns not found when the account feature is disabled' do
    account.disable_features!('captain_integration')

    expect { post_report }.not_to change(Captain::MessageReport, :count)

    expect(response).to have_http_status(:not_found)
  end

  it 'creates a tenant-derived report and omits raw feedback from the response' do
    expect { post_report }.to change(Captain::MessageReport, :count).by(1)

    report = Captain::MessageReport.last
    aggregate_failures do
      expect(response).to have_http_status(:created)
      expect(report).to have_attributes(
        account_id: account.id,
        conversation_id: conversation.id,
        message_id: message.id,
        user_id: agent.id,
        report_reason: 'incorrect_information',
        description: 'The generated citation is wrong.'
      )
      expect(json_response).to include(
        id: report.id,
        report_reason: 'incorrect_information',
        description_present: true,
        revised: false
      )
      expect(json_response).not_to have_key(:description)
    end
  end

  it 'revises the effective report instead of creating a duplicate' do
    post_report
    report_id = json_response.fetch(:id)

    expect do
      post_report(params: valid_params.merge(report_reason: 'outdated_information', description: 'Updated reason'))
    end.not_to change(Captain::MessageReport, :count)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(json_response).to include(id: report_id, report_reason: 'outdated_information', revised: true)
      expect(Captain::MessageReport.find(report_id).description).to eq('Updated reason')
    end
  end

  it 'sanitizes and redacts feedback before persistence' do
    post_report(params: valid_params.merge(description: '<b>person@example.com +61 412 345 678</b> Bearer abcdefghijklmnop'))

    expect(Captain::MessageReport.last.description).to eq(
      '[REDACTED_EMAIL] [REDACTED_PHONE] [REDACTED_SECRET]'
    )
  end

  it 'rejects an invalid reason and oversized input' do
    post_report(params: valid_params.merge(report_reason: 'invalid_reason'))
    expect(response).to have_http_status(:unprocessable_content)

    post_report(params: valid_params.merge(description: 'x' * (Captain::MessageReport::MAX_DESCRIPTION_INPUT_BYTES + 1)))
    expect(response).to have_http_status(:unprocessable_content)
    expect(Captain::MessageReport.count).to eq(0)
  end

  it 'does not reveal a message from another account' do
    other_message = create(:message)

    post_report(params: valid_params.merge(message_id: other_message.id))

    expect(response).to have_http_status(:not_found)
  end

  it 'requires access to the conversation' do
    inaccessible_agent = create(:user, account: account, role: :agent)

    post_report(user: inaccessible_agent)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'accepts only public outgoing Captain assistant replies' do
    ordinary_message = create(
      :message,
      account: account,
      conversation: conversation,
      sender: agent,
      message_type: :outgoing
    )

    post_report(params: valid_params.merge(message_id: ordinary_message.id))

    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'emits only metadata and records that no external egress occurred' do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('lla.captain.message_feedback') do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload
    end

    post_report(params: valid_params.merge(description: 'private free-form feedback'))

    expect(events).to contain_exactly(include(external_egress: false, account_id: account.id, message_id: message.id))
    expect(events.to_json).not_to include('private free-form feedback')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
