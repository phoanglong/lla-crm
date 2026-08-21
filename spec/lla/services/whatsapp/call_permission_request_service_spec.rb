# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::CallPermissionRequestService do
  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', account: account,
                              validate_provider_config: false, sync_templates: false)
  end
  let(:inbox) { channel.inbox }
  let(:user) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+15550001111') }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact, source_id: '15550001111') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox).reload
  end
  let(:permission_url) { 'https://graph.facebook.com/v22.0/123456789/messages' }

  before do
    account.enable_features!('channel_voice')
    channel.update!(provider_config: channel.provider_config.merge('calling_enabled' => true))
    create(:inbox_member, inbox: inbox, user: user)
    stub_request(:post, permission_url)
      .to_return(status: 200, body: { messages: [{ id: 'wamid.permission-spec-1' }] }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  def perform_request
    described_class.new(conversation: conversation, user: user).perform
  end

  it 'records only the provider-message digest and completes an operation' do
    expect(perform_request).to eq('permission_requested')

    attrs = conversation.reload.additional_attributes
    expect(attrs['call_permission_request_message_id']).to be_nil
    expect(attrs['call_permission_request_message_id_digest'])
      .to eq(Digest::SHA256.hexdigest('wamid.permission-spec-1'))
    expect(Lla::Voice::CallOperation.last).to have_attributes(action: 'permission_request', state: 'succeeded')
  end

  it 'throttles a duplicate request without calling Meta twice' do
    expect(perform_request).to eq('permission_requested')
    expect(perform_request).to eq('permission_pending')

    expect(a_request(:post, permission_url)).to have_been_made.once
  end

  it 'honors the failure backoff without hammering Meta' do
    stub_request(:post, permission_url).to_timeout

    expect(perform_request).to eq('failed')
    expect(perform_request).to eq('failed')

    expect(a_request(:post, permission_url)).to have_been_made.once
    expect(Lla::Voice::CallOperation.last.state).to eq('failed')
  end
end
