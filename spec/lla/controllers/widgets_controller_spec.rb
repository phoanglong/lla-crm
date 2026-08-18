# frozen_string_literal: true

require 'rails_helper'

# Controller-boundary spec for the LLA widget geo consumer. Uses type: :controller so
# the widget view (Vite assets) is not rendered; asserts the HTTP mapping of each
# gatekeeper outcome. Runs identically under EE ON and DISABLE_ENTERPRISE=true.
RSpec.describe WidgetsController, type: :controller do
  let(:account) { create(:account) }
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:ip_lookup) { instance_double(IpLookupService) }

  around do |example|
    with_modified_env('LLA_WIDGET_GEOIP_ENABLED' => 'true') { example.run }
  end

  before do
    allow(IpLookupService).to receive(:new).and_return(ip_lookup)
    allow(ip_lookup).to receive(:perform).and_return(OpenStruct.new(country_code: 'US'))
    account.enable_features!('ip_lookup')
    configure_geo('allowed_countries' => %w[US VN],
                  'widget_geoip_policy' => { 'enabled' => true, 'consent_enabled' => true, 'mode' => 'strict' })
  end

  def configure_geo(attributes)
    account.update!(custom_attributes: account.custom_attributes.merge(attributes))
  end

  def show!
    get :show, params: { website_token: web_widget.website_token }
  end

  it 'allows a request resolved to a listed country' do
    show!
    expect(response).to have_http_status(:ok)
  end

  it 'rejects a request resolved to an unlisted country' do
    allow(ip_lookup).to receive(:perform).and_return(OpenStruct.new(country_code: 'JP'))
    show!
    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns 422 with a stable code for a present-but-empty allowlist' do
    configure_geo('allowed_countries' => [])
    show!
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['code']).to eq('geoip_policy_invalid')
    expect(ip_lookup).not_to have_received(:perform)
  end

  it 'returns 422 for an unassigned ISO code such as ZZ before any provider call' do
    configure_geo('allowed_countries' => %w[ZZ])
    show!
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ip_lookup).not_to have_received(:perform)
  end

  it 'returns 401 geoip_lookup_unavailable for malformed provider output (strict)' do
    allow(ip_lookup).to receive(:perform).and_return(OpenStruct.new(country_code: 'USA'))
    show!
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body['code']).to eq('geoip_lookup_unavailable')
  end

  it 'maps an expected provider timeout to 401 geoip_lookup_unavailable, not a 500' do
    allow(ip_lookup).to receive(:perform).and_raise(Timeout::Error)
    show!
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body['code']).to eq('geoip_lookup_unavailable')
  end

  it 'allows and skips the provider when GeoIP is disabled for the account' do
    configure_geo('widget_geoip_policy' => { 'enabled' => false, 'consent_enabled' => true })
    show!
    expect(response).to have_http_status(:ok)
    expect(ip_lookup).not_to have_received(:perform)
  end
end
