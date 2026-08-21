# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Twilio::VoiceTeardownService do
  let(:account_sid) { 'ACaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
  let(:api_key_sid) { 'SKaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
  let(:api_key_secret) { 'api_key_secret_123' }
  let(:phone_number) { '+15551230001' }
  let(:phone_number_sid) { 'PN123' }
  let(:twiml_app_sid) { 'AP123' }
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_twilio_sms, :with_voice, account: account, phone_number: phone_number, account_sid: account_sid,
                                        api_key_sid: api_key_sid, api_key_secret: api_key_secret,
                                        twiml_app_sid: twiml_app_sid
    )
  end
  let(:base_url) { "https://api.twilio.com/2010-04-01/Accounts/#{account_sid}" }
  let(:numbers_url) { "#{base_url}/IncomingPhoneNumbers.json" }
  let(:number_url) { "#{base_url}/IncomingPhoneNumbers/#{phone_number_sid}.json" }
  let(:application_url) { "#{base_url}/Applications/#{twiml_app_sid}.json" }

  before do
    stub_request(:get, /#{Regexp.escape(numbers_url)}.*/)
      .with(basic_auth: [api_key_sid, api_key_secret])
      .to_return(status: 200,
                 body: { incoming_phone_numbers: [{ sid: phone_number_sid }], meta: { key: 'incoming_phone_numbers' } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
    stub_request(:post, number_url)
      .with(basic_auth: [api_key_sid, api_key_secret])
      .to_return(status: 200, body: { sid: phone_number_sid }.to_json, headers: { 'Content-Type' => 'application/json' })
    stub_request(:delete, application_url)
      .with(basic_auth: [api_key_sid, api_key_secret])
      .to_return(status: 204)
  end

  it 'clears provider webhooks before deleting the app and then clears the local SID' do
    expect(described_class.new(channel: channel).perform).to be true

    expect(a_request(:post, number_url).with(body: hash_including('VoiceUrl' => '', 'StatusCallback' => ''))).to have_been_made.once
    expect(a_request(:delete, application_url)).to have_been_made.once
    expect(channel.reload.twiml_app_sid).to be_nil
  end

  it 'retains the local SID when provider teardown fails' do
    stub_request(:post, number_url).to_return(status: 500, body: '{}')

    expect { described_class.new(channel: channel).perform }.to raise_error(Twilio::REST::RestError)

    expect(a_request(:delete, application_url)).not_to have_been_made
    expect(channel.reload.twiml_app_sid).to eq(twiml_app_sid)
  end
end
