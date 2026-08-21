require 'rails_helper'

RSpec.describe 'Bandwidth SMS callback authentication', type: :request do
  let(:account) { create(:account) }
  let(:payload) { [{ type: 'message-received', message: { text: 'chào' } }].to_json }

  def post_callback(phone, headers = {})
    post "/webhooks/sms/#{phone}", params: payload,
                                   headers: { 'CONTENT_TYPE' => 'application/json' }.merge(headers)
  end

  it 'accepts a callback for a channel that has no credentials configured' do
    channel = create(:channel_sms, account: account)

    expect { post_callback(channel.phone_number) }.to have_enqueued_job(Webhooks::SmsEventsJob)
    expect(response).to have_http_status(:success)
  end

  context 'when the tenant configured callback credentials' do
    let(:channel) do
      create(:channel_sms, account: account,
                           provider_config: { 'callback_username' => 'bw-user', 'callback_password' => 'bw-pass' })
    end

    it 'refuses an unauthenticated callback and asks Bandwidth to authenticate' do
      expect { post_callback(channel.phone_number) }.not_to have_enqueued_job(Webhooks::SmsEventsJob)

      aggregate_failures do
        expect(response).to have_http_status(:unauthorized)
        expect(response.headers['WWW-Authenticate']).to start_with('Basic')
      end
    end

    it 'refuses the wrong password' do
      post_callback(channel.phone_number,
                    { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials('bw-user', 'sai') })

      expect(response).to have_http_status(:unauthorized)
    end

    it 'accepts the credentials the tenant configured' do
      expect do
        post_callback(channel.phone_number,
                      { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials('bw-user', 'bw-pass') })
      end.to have_enqueued_job(Webhooks::SmsEventsJob)

      expect(response).to have_http_status(:success)
    end
  end
end
