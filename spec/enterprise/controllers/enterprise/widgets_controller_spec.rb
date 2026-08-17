# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Enterprise widget geo policy', type: :request do
  let(:account) { create(:account) }
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:service) { instance_double(IpLookupService) }
  let(:geo_result) { OpenStruct.new(country_code: 'US') }

  around do |example|
    with_modified_env('LLA_WIDGET_GEOIP_ENABLED' => 'true') { example.run }
  end

  before do
    allow(IpLookupService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_return(geo_result)
    account.enable_features!('ip_lookup')
    account.update!(custom_attributes: account.custom_attributes.merge(
                      'allowed_countries' => ['US', 'VN'],
                      'widget_geoip_policy' => {
                        'enabled' => true,
                        'consent_enabled' => true,
                        'mode' => 'strict'
                      }
                    ))
  end

  it 'permits request when country is allowed' do
    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:success)
    expect(service).to have_received(:perform).once
  end

  it 'rejects mixed-case allowlist values with stable validation code' do
    account.update!(custom_attributes: account.custom_attributes.merge('allowed_countries' => ['Us', 'VN']))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['code']).to eq('geoip_policy_invalid')
    expect(service).not_to have_received(:perform)
  end

  it 'rejects duplicate and empty allowlist values' do
    account.update!(custom_attributes: account.custom_attributes.merge('allowed_countries' => ['US', '', 'US']))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(service).not_to have_received(:perform)
  end

  it 'rejects oversized allowlist payload' do
    oversized = Array.new(251) { 'US' }.each_with_index.map { |_code, idx| (idx % 2).zero? ? 'US' : 'VN' }
    account.update!(custom_attributes: account.custom_attributes.merge('allowed_countries' => oversized))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['code']).to eq('country_allowlist_too_large')
    expect(service).not_to have_received(:perform)
  end

  it 'returns unauthorized when lookup country is not allowed' do
    allow(service).to receive(:perform).and_return(OpenStruct.new(country_code: 'JP'))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'denies in strict mode when provider is unavailable' do
    allow(service).to receive(:perform).and_return(nil)

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body['code']).to eq('geoip_lookup_unavailable')
  end

  it 'allows in open mode when provider is unavailable' do
    account.update!(custom_attributes: account.custom_attributes.merge(
                      'widget_geoip_policy' => {
                        'enabled' => true,
                        'consent_enabled' => true,
                        'mode' => 'open'
                      }
                    ))
    allow(service).to receive(:perform).and_return(nil)

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:success)
  end

  it 'does not call provider when consent is disabled (zero egress)' do
    account.update!(custom_attributes: account.custom_attributes.merge(
                      'widget_geoip_policy' => {
                        'enabled' => true,
                        'consent_enabled' => false,
                        'mode' => 'strict'
                      }
                    ))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:success)
    expect(service).not_to have_received(:perform)
  end

  it 'does not trust spoofed forwarded IP from untrusted proxy' do
    get widget_url(website_token: web_widget.website_token),
        headers: {
          'REMOTE_ADDR' => '203.0.113.9',
          'HTTP_X_FORWARDED_FOR' => '8.8.8.8'
        }

    expect(service).to have_received(:perform).with('203.0.113.9')
  end

  it 'uses forwarded IP only when proxy is trusted' do
    get widget_url(website_token: web_widget.website_token),
        headers: {
          'REMOTE_ADDR' => '127.0.0.1',
          'HTTP_X_FORWARDED_FOR' => '8.8.4.4'
        }

    expect(service).to have_received(:perform).with('8.8.4.4')
  end
end
