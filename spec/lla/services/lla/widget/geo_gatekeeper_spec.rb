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

    it 'maps an expected provider timeout to a typed strict deny, not a 500' do
      allow(ip_lookup).to receive(:perform).and_raise(Timeout::Error)
      decision = gatekeeper.call
      expect(decision.outcome).to eq(:deny)
      expect(decision.reason).to eq('geoip_lookup_unavailable')
    end

    it 'fails open for an expected provider timeout when mode is open' do
      configure_geo('widget_geoip_policy' => { 'enabled' => true, 'consent_enabled' => true, 'mode' => 'open' })
      allow(ip_lookup).to receive(:perform).and_raise(SocketError)
      expect(gatekeeper.call.outcome).to eq(:allow)
    end

    it 'does not rescue an unexpected programming error' do
      allow(ip_lookup).to receive(:perform).and_raise(NoMethodError)
      expect { gatekeeper.call }.to raise_error(NoMethodError)
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

    it 'rate-bounds a malformed (unavailable) result to one lookup within the TTL' do
      allow(ip_lookup).to receive(:perform).and_return(OpenStruct.new(country_code: 'USA'))
      2.times { expect(gatekeeper.call.reason).to eq('geoip_lookup_unavailable') }
      expect(ip_lookup).to have_received(:perform).once
    end

    it 'rate-bounds a provider timeout (unavailable) to one lookup within the TTL' do
      allow(ip_lookup).to receive(:perform).and_raise(Timeout::Error)
      2.times { gatekeeper.call }
      expect(ip_lookup).to have_received(:perform).once
    end

    it 'looks up again after the positive-country TTL expires' do
      gatekeeper.call
      travel(described_class::CACHE_TTL + 1.second) { gatekeeper.call }
      expect(ip_lookup).to have_received(:perform).twice
    end

    it 'looks up again after the shorter unavailable TTL expires' do
      allow(ip_lookup).to receive(:perform).and_return(nil)
      gatekeeper.call
      travel(described_class::UNAVAILABLE_CACHE_TTL + 1.second) { gatekeeper.call }
      expect(ip_lookup).to have_received(:perform).twice
    end

    it 'does not confuse the unavailable sentinel with a real country' do
      allow(ip_lookup).to receive(:perform).and_return(nil)
      gatekeeper.call
      expect(gatekeeper.call.outcome).to eq(:deny)
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
      keys = cache.instance_variable_get(:@data).keys
      expect(keys).to be_present
      expect(keys).to all(satisfy { |key| key.include?(account.id.to_s) && key.exclude?(client_ip) })
    end
  end

  describe 'concurrent single-flight coalescing (barrier + threads)' do
    let(:call_count) { Concurrent::AtomicFixnum.new(0) }

    def run_concurrent(threads: 8)
      barrier = Concurrent::CyclicBarrier.new(threads)
      gatekeepers = Array.new(threads) do
        described_class.new(web_widget: web_widget, client_ip: client_ip, global_enabled: true,
                            ip_lookup: ip_lookup, cache: cache)
      end
      gatekeepers.map do |gk|
        Thread.new do
          barrier.wait
          gk.call
        end
      end.each(&:join)
    end

    it 'coalesces a simultaneous valid miss group to one provider call' do
      allow(ip_lookup).to receive(:perform) { call_count.increment && OpenStruct.new(country_code: 'US') }
      run_concurrent
      expect(call_count.value).to eq(1)
    end

    it 'coalesces a simultaneous malformed miss group to one provider call' do
      allow(ip_lookup).to receive(:perform) { call_count.increment && OpenStruct.new(country_code: 'USA') }
      run_concurrent
      expect(call_count.value).to eq(1)
    end

    it 'coalesces a simultaneous expected-error miss group to one provider call' do
      allow(ip_lookup).to receive(:perform) { call_count.increment && raise(Timeout::Error) }
      run_concurrent
      expect(call_count.value).to eq(1)
    end

    it 'does not let a different tenant/widget/IP key block or leak the cache' do
      allow(ip_lookup).to receive(:perform) { call_count.increment && OpenStruct.new(country_code: 'US') }
      other_account = create(:account)
      other_account.enable_features!('ip_lookup')
      other_account.update!(custom_attributes: account.custom_attributes)
      other_widget = create(:channel_widget, account: other_account)

      gatekeeper.call
      described_class.new(web_widget: other_widget, client_ip: '198.51.100.5', global_enabled: true,
                          ip_lookup: ip_lookup, cache: cache).call

      expect(call_count.value).to eq(2)
    end
  end
end
