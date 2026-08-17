# frozen_string_literal: true

require 'rails_helper'

# Deterministic boundary spec for the widget GeoIP decision. No Vite/rendering and no
# real provider/network calls; runs identically under EE ON and DISABLE_ENTERPRISE=true.
RSpec.describe Lla::Widget::GeoGatekeeper do
  subject(:gatekeeper) do
    described_class.new(
      web_widget: web_widget,
      client_ip: client_ip,
      global_enabled: global_enabled,
      ip_lookup: ip_lookup,
      cache: cache
    )
  end

  let(:account) { create(:account) }
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:client_ip) { '203.0.113.7' }
  let(:global_enabled) { true }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:ip_lookup) { instance_double(IpLookupService) }
  let(:provider_country) { 'US' }

  before do
    allow(ip_lookup).to receive(:perform).and_return(OpenStruct.new(country_code: provider_country))
    account.enable_features!('ip_lookup')
    configure_geo('allowed_countries' => %w[US VN],
                  'widget_geoip_policy' => { 'enabled' => true, 'consent_enabled' => true, 'mode' => 'strict' })
  end

  def configure_geo(attributes)
    account.update!(custom_attributes: account.custom_attributes.merge(attributes))
  end

  describe 'enforcement decisions' do
    it 'allows an IP resolved to a listed country' do
      expect(gatekeeper.call.outcome).to eq(:allow)
    end

    it 'denies an IP resolved to an unlisted country' do
      allow(ip_lookup).to receive(:perform).and_return(OpenStruct.new(country_code: 'JP'))
      decision = gatekeeper.call
      expect(decision.outcome).to eq(:deny)
      expect(decision.reason).to eq('country_not_allowed')
    end

    it 'canonicalizes mixed-case allowlist entries before matching' do
      configure_geo('allowed_countries' => %w[us vn])
      expect(gatekeeper.call.outcome).to eq(:allow)
    end
  end

  describe 'configuration validation (zero egress on error)' do
    it 'rejects a present-but-empty allowlist with a stable code' do
      configure_geo('allowed_countries' => [])
      expect { gatekeeper.call }.to raise_error(Lla::Widget::GeoConfigurationError) { |e| expect(e.code).to eq('geoip_policy_invalid') }
      expect(ip_lookup).not_to have_received(:perform)
    end

    it 'rejects an unassigned ISO code such as ZZ before any provider call' do
      configure_geo('allowed_countries' => %w[ZZ])
      expect { gatekeeper.call }.to raise_error(Lla::Widget::GeoConfigurationError) { |e| expect(e.code).to eq('geoip_policy_invalid') }
      expect(ip_lookup).not_to have_received(:perform)
    end

    it 'rejects a blank entry before any provider call' do
      configure_geo('allowed_countries' => ['US', ''])
      expect { gatekeeper.call }.to raise_error(Lla::Widget::GeoConfigurationError)
      expect(ip_lookup).not_to have_received(:perform)
    end

    it 'rejects duplicates after canonicalization' do
      configure_geo('allowed_countries' => %w[US us])
      expect { gatekeeper.call }.to raise_error(Lla::Widget::GeoConfigurationError) { |e| expect(e.code).to eq('country_allowlist_duplicate') }
      expect(ip_lookup).not_to have_received(:perform)
    end

    it 'rejects an oversized allowlist payload' do
      configure_geo('allowed_countries' => Array.new(Lla::Widget::IsoCountryRegistry::ALPHA2.size + 1, 'US'))
      expect { gatekeeper.call }.to raise_error(Lla::Widget::GeoConfigurationError) { |e| expect(e.code).to eq('country_allowlist_too_large') }
      expect(ip_lookup).not_to have_received(:perform)
    end
  end

  describe 'malformed provider output' do
    it 'treats a non-ISO provider code (USA) as unavailable, not a mismatch (strict = deny)' do
      allow(ip_lookup).to receive(:perform).and_return(OpenStruct.new(country_code: 'USA'))
      decision = gatekeeper.call
      expect(decision.outcome).to eq(:deny)
      expect(decision.reason).to eq('geoip_lookup_unavailable')
    end

    it 'fails open for malformed provider output when mode is open' do
      configure_geo('widget_geoip_policy' => { 'enabled' => true, 'consent_enabled' => true, 'mode' => 'open' })
      allow(ip_lookup).to receive(:perform).and_return(OpenStruct.new(country_code: 'USA'))
      expect(gatekeeper.call.outcome).to eq(:allow)
    end

    it 'treats a nil provider result as unavailable (strict = deny)' do
      allow(ip_lookup).to receive(:perform).and_return(nil)
      expect(gatekeeper.call.reason).to eq('geoip_lookup_unavailable')
    end
  end

  describe 'zero-egress gates' do
    it 'bypasses and never calls the provider when the allowlist key is absent' do
      account.update!(custom_attributes: account.custom_attributes.except('allowed_countries'))
      expect(gatekeeper.call.outcome).to eq(:bypass)
      expect(ip_lookup).not_to have_received(:perform)
    end

    it 'bypasses with zero egress when the global env gate is off' do
      expect(described_class.new(web_widget: web_widget, client_ip: client_ip, global_enabled: false,
                                 ip_lookup: ip_lookup, cache: cache).call.outcome).to eq(:bypass)
      expect(ip_lookup).not_to have_received(:perform)
    end

    it 'bypasses with zero egress when the ip_lookup capability is off' do
      account.disable_features!('ip_lookup')
      expect(gatekeeper.call.outcome).to eq(:bypass)
      expect(ip_lookup).not_to have_received(:perform)
    end

    it 'bypasses with zero egress when the account policy is disabled' do
      configure_geo('widget_geoip_policy' => { 'enabled' => false, 'consent_enabled' => true })
      expect(gatekeeper.call.outcome).to eq(:bypass)
      expect(ip_lookup).not_to have_received(:perform)
    end

    it 'bypasses with zero egress when provider consent is withdrawn' do
      configure_geo('widget_geoip_policy' => { 'enabled' => true, 'consent_enabled' => false })
      expect(gatekeeper.call.outcome).to eq(:bypass)
      expect(ip_lookup).not_to have_received(:perform)
    end
  end

  describe 'cache, rate and tenant isolation' do
    it 'calls the provider once per tenant/widget/IP within the TTL (bounded rate)' do
      2.times { gatekeeper.call }
      expect(ip_lookup).to have_received(:perform).once
    end

    it 'does not share cached decisions across accounts (tenant isolation)' do
      other_account = create(:account)
      other_account.enable_features!('ip_lookup')
      other_account.update!(custom_attributes: account.custom_attributes)
      other_widget = create(:channel_widget, account: other_account)

      gatekeeper.call
      described_class.new(web_widget: other_widget, client_ip: client_ip, global_enabled: true,
                          ip_lookup: ip_lookup, cache: cache).call

      expect(ip_lookup).to have_received(:perform).twice
    end

    it 'never stores the raw client IP in the cache key' do
      gatekeeper.call
      key = cache.instance_variable_get(:@data).keys.first
      expect(key).to include(account.id.to_s, web_widget.id.to_s)
      expect(key).not_to include(client_ip)
    end
  end
end
