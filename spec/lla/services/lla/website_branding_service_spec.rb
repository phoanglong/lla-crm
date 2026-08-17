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

  def consent!(*providers)
    consents = providers.index_with { { 'enabled' => true, 'version' => 'v1', 'accepted_at' => 1.day.ago.iso8601 } }
    account.update!(custom_attributes: account.custom_attributes.merge('lla_provider_consents' => consents))
  end

  # Spy at both egress boundaries the service can reach: the HTTP fetcher used by
  # the local scrape and the DNS resolver used by the MX probe.
  def expect_no_network
    allow(SafeFetch).to receive(:fetch)
    allow(Resolv::DNS).to receive(:open).and_return([])

    yield

    expect(SafeFetch).not_to have_received(:fetch)
    expect(Resolv::DNS).not_to have_received(:open)
    expect(WebMock).not_to have_requested(:any, //)
  end

  describe 'zero egress by default' do
    it 'does not call Context, does not scrape and does not resolve DNS' do
      expect_no_network do
        expect(WebsiteBrandingService.new(email, account: account).perform).to be_nil
      end
    end

    it 'stays inert when the flags are on but the account has consented to nothing' do
      expect_no_network do
        with_modified_env(enabled_env) do
          expect(WebsiteBrandingService.new(email, account: account).perform).to be_nil
        end
      end
    end

    it 'stays inert when no account is supplied at all' do
      consent!('context_dev', 'direct_fetch')

      expect_no_network do
        with_modified_env(enabled_env) { expect(WebsiteBrandingService.new(email).perform).to be_nil }
      end
    end
  end

  describe 'Context.dev adapter' do
    before { consent!('context_dev') }

    it 'uses the provider once fully enabled and bounds the untrusted payload' do
      stub_request(:get, /api\.context\.dev/)
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

    it 'does not probe MX records while direct fetch is not consented' do
      stub_request(:get, /api\.context\.dev/)
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { 'brand' => { 'title' => 'Brand' } }.to_json)
      allow(Resolv::DNS).to receive(:open).and_return([])

      result = with_modified_env(enabled_env) { WebsiteBrandingService.new(email, account: account).perform }

      expect(result[:email_provider]).to be_nil
      expect(Resolv::DNS).not_to have_received(:open)
    end

    it 'does not fall through to the local scrape when direct fetch is not consented' do
      stub_request(:get, /api\.context\.dev/).to_return(status: 502, body: 'upstream exploded')
      allow(SafeFetch).to receive(:fetch)

      result = with_modified_env(enabled_env) { WebsiteBrandingService.new(email, account: account).perform }

      expect(result).to be_nil
      expect(SafeFetch).not_to have_received(:fetch)
    end

    it 'logs only a status code, never the provider body, credential or email' do
      stub_request(:get, /api\.context\.dev/).to_return(status: 502, body: 'upstream exploded')
      allow(Rails.logger).to receive(:warn)

      with_modified_env(enabled_env) { WebsiteBrandingService.new(email, account: account).perform }

      expect(Rails.logger).to have_received(:warn).with('[LlaWebsiteBranding] context_dev_status=502')
      expect(Rails.logger).not_to have_received(:warn).with(/upstream exploded/)
      expect(Rails.logger).not_to have_received(:warn).with(/context-key-1234567890|owner@brand/)
    end
  end

  describe 'local fallback' do
    before { consent!('context_dev', 'direct_fetch') }

    it 'is used when Context fails and direct fetch is consented' do
      stub_request(:get, /api\.context\.dev/).to_return(status: 502, body: '')
      allow(SafeFetch).to receive(:fetch)
      allow(Resolv::DNS).to receive(:open).and_return([])

      with_modified_env(enabled_env) { WebsiteBrandingService.new(email, account: account).perform }

      expect(SafeFetch).to have_received(:fetch).with('https://brand.example.com', validate_content_type: false)
    end
  end
end
