# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Accounts::Contacts::CallsController, type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+15550001111') }
  let(:channel) { create(:channel_twilio_sms, :with_voice, account: account, twiml_app_sid: 'AP12345678') }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:call) do
    create(:call, account: account, inbox: inbox, contact: contact, conversation: conversation,
                  provider: :twilio, provider_call_id: 'CA12345678', conference_sid: 'CF12345678')
  end
  let(:path) { "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/call" }

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, inbox: inbox, user: agent)
  end

  it 'passes the idempotency key and tenant-scoped records to the builder' do
    allow(Voice::OutboundCallBuilder).to receive(:perform!).and_return(call)

    post path,
         headers: agent.create_new_auth_token.merge('Idempotency-Key' => 'voice-request-123'),
         params: { inbox_id: inbox.id, conversation_id: conversation.display_id }

    expect(response).to have_http_status(:ok)
    expect(Voice::OutboundCallBuilder).to have_received(:perform!).with(
      account: account,
      inbox: inbox,
      user: agent,
      contact: contact,
      conversation: conversation,
      idempotency_key: 'voice-request-123'
    )
    expect(response.parsed_body).to include('conversation_id' => conversation.display_id, 'call_sid' => 'CA12345678')
  end

  it 'does not expose the route to an agent without inbox access' do
    outsider = create(:user, account: account)

    post path,
         headers: outsider.create_new_auth_token.merge('Idempotency-Key' => 'voice-request-123'),
         params: { inbox_id: inbox.id }

    expect(response).to have_http_status(:not_found)
  end

  it 'rejects outbound calling when the account feature is disabled' do
    account.disable_features!('channel_voice')

    post path,
         headers: agent.create_new_auth_token.merge('Idempotency-Key' => 'voice-request-123'),
         params: { inbox_id: inbox.id }

    expect(response).to have_http_status(:unauthorized)
  end
end
