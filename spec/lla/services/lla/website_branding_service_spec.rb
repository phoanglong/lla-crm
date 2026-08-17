# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::WebsiteBrandingService do
  let(:account) { create(:account) }
  let(:email) { 'owner@brand.example.com' }
  let(:enabled_env) do
    {
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_WEBSITE_ENRICHMENT_ENABLED' => 'true',
      'LLA_CONTEXT_DEV_API_KEY_REF' => 'infisical://lla/dev/context#CONTEXT_DEV_API_KEY',
      'CONTEXT_DEV_API_KEY' => 'context-key-1234567890'
    }
  end

  def consent!
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'context_dev' => { 'enabled' => true, 'version' => 'v1', 'accepted_at' => 1.day.ago.iso8601 }
      }
    ))
  end

  def stub_local_scrape
    allow_any_instance_of(WebsiteBrandingService).to receive(:fetch_page).and_return(nil) # rubocop:disable RSpec/AnyInstance
  end

  it 'is inert without the capability, consent or secret reference' do
    stub_local_scrape

    WebsiteBrandingService.new(email, account: account).perform
    with_modified_env(enabled_env) { WebsiteBrandingService.new(email, account: account).perform }

    expect(WebMock).not_to have_requested(:any, /context\.dev/)
  end

  it 'never calls the provider when no account is supplied' do
    stub_local_scrape
    consent!

    with_modified_env(enabled_env) { WebsiteBrandingService.new(email).perform }

    expect(WebMock).not_to have_requested(:any, /context\.dev/)
  end

  it 'uses the provider once fully enabled and bounds the untrusted payload' do
    consent!
    stub_request(:get, %r{api\.context\.dev/v1/brand/retrieve-by-email})
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: {
                   'brand' => {
                     'title' => 'Brand ' * 400,
                     'colors' => [{ 'hex' => '#123456' }, { 'hex' => 'javascript:alert(1)' }],
                     'logos' => [{ 'url' => 'https://cdn.brand.example.com/logo.png' },
                                 { 'url' => 'javascript:alert(1)' },
                                 { 'url' => 'file:///etc/passwd' }],
                     'socials' => [{ 'type' => 'facebook', 'url' => 'https://facebook.com/brand' },
                                   { 'type' => 'x', 'url' => 'http://169.254.169.254/latest' }]
                   }
                 }.to_json)

    result = with_modified_env(enabled_env) { WebsiteBrandingService.new(email, account: account).perform }

    expect(result[:title].length).to eq(described_class::MAX_TEXT_LENGTH)
    expect(result[:colors]).to eq([{ hex: '#123456', name: nil }])
    expect(result[:logos].pluck(:url)).to eq(['https://cdn.brand.example.com/logo.png'])
    expect(result[:socials].pluck(:type)).to eq(%w[facebook x])
  end

  it 'falls back to the local scrape and logs no provider body on failure' do
    consent!
    stub_request(:get, /api\.context\.dev/).to_return(status: 502, body: 'upstream exploded')
    allow(Rails.logger).to receive(:warn)
    stub_local_scrape

    with_modified_env(enabled_env) { WebsiteBrandingService.new(email, account: account).perform }

    expect(Rails.logger).to have_received(:warn).with('[LlaWebsiteBranding] context_dev_status=502')
    expect(Rails.logger).not_to have_received(:warn).with(/upstream exploded/)
  end

  it 'never writes the credential or the email into the log line' do
    consent!
    stub_request(:get, /api\.context\.dev/).to_timeout
    allow(Rails.logger).to receive(:warn)
    stub_local_scrape

    with_modified_env(enabled_env) { WebsiteBrandingService.new(email, account: account).perform }

    expect(Rails.logger).not_to have_received(:warn).with(/context-key-1234567890|owner@brand/)
  end
end
