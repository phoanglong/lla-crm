# frozen_string_literal: true

require 'rails_helper'

# Widget country/GeoIP allowlist enforcement (Lla::WidgetsController). Runs identically
# under EE ON and DISABLE_ENTERPRISE=true. No real GeoIP/provider/network calls are made.
RSpec.describe 'LLA widget geo policy', type: :request do
  let(:account) { create(:account) }
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:service) { instance_double(IpLookupService) }
  let(:geo_result) { OpenStruct.new(country_code: 'US') }

  around do |example|
    with_modified_env('LLA_WIDGET_GEOIP_ENABLED' => 'true') { example.run }
  end

  before do
    # The widget page renders Vite-managed assets whose binary is absent in this test
    # environment; pretend the dev server is running so tags emit URLs without bundling.
    allow(ViteRuby.instance).to receive(:dev_server_running?).and_return(true)
    allow(IpLookupService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_return(geo_result)
    account.enable_features!('ip_lookup')
    account.update!(custom_attributes: account.custom_attributes.merge(
      'allowed_countries' => %w[US VN],
      'widget_geoip_policy' => { 'enabled' => true, 'consent_enabled' => true, 'mode' => 'strict' }
    ))
  end

  it 'permits a request from an allowed country' do
    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:success)
    expect(service).to have_received(:perform).once
  end

  it 'rejects a request from a country outside the allowlist' do
    allow(service).to receive(:perform).and_return(OpenStruct.new(country_code: 'JP'))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects mixed-case allowlist values with a stable validation code' do
    account.update!(custom_attributes: account.custom_attributes.merge('allowed_countries' => %w[Us VN]))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['code']).to eq('geoip_policy_invalid')
    expect(service).not_to have_received(:perform)
  end

  it 'rejects empty and duplicate allowlist values' do
    account.update!(custom_attributes: account.custom_attributes.merge('allowed_countries' => ['US', '', 'US']))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(service).not_to have_received(:perform)
  end

  it 'rejects an oversized allowlist payload' do
    oversized = Array.new(251) { |idx| idx.even? ? 'US' : 'VN' }
    account.update!(custom_attributes: account.custom_attributes.merge('allowed_countries' => oversized))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['code']).to eq('country_allowlist_too_large')
    expect(service).not_to have_received(:perform)
  end

  it 'denies (fail-closed) in strict mode when the provider is unavailable' do
    allow(service).to receive(:perform).and_return(nil)

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body['code']).to eq('geoip_lookup_unavailable')
  end

  it 'allows (fail-open) in open mode when the provider is unavailable' do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'widget_geoip_policy' => { 'enabled' => true, 'consent_enabled' => true, 'mode' => 'open' }
    ))
    allow(service).to receive(:perform).and_return(nil)

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:success)
  end

  it 'makes zero provider calls when consent is disabled' do
    account.update!(custom_attributes: account.custom_attributes.merge(
      'widget_geoip_policy' => { 'enabled' => true, 'consent_enabled' => false, 'mode' => 'strict' }
    ))

    get widget_url(website_token: web_widget.website_token)

    expect(response).to have_http_status(:success)
    expect(service).not_to have_received(:perform)
  end

  it 'makes zero provider calls when the global env gate is off' do
    with_modified_env('LLA_WIDGET_GEOIP_ENABLED' => 'false') do
      get widget_url(website_token: web_widget.website_token)
    end

    expect(response).to have_http_status(:success)
    expect(service).not_to have_received(:perform)
  end

  it 'ignores a spoofed forwarded IP from an untrusted proxy' do
    get widget_url(website_token: web_widget.website_token),
        headers: { 'REMOTE_ADDR' => '203.0.113.9', 'HTTP_X_FORWARDED_FOR' => '8.8.8.8' }

    expect(service).to have_received(:perform).with('203.0.113.9')
  end

  it 'honours the forwarded IP only when the proxy is trusted' do
    get widget_url(website_token: web_widget.website_token),
        headers: { 'REMOTE_ADDR' => '127.0.0.1', 'HTTP_X_FORWARDED_FOR' => '8.8.4.4' }

    expect(service).to have_received(:perform).with('8.8.4.4')
  end
end
