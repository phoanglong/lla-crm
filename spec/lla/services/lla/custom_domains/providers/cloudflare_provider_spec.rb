# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::Providers::CloudflareProvider do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:domain) do
    Lla::CustomDomains::Domain.create!(account_id: account.id, portal_id: portal.id,
                                       hostname: 'docs.example.com', state: 'provisioning',
                                       provider: 'cloudflare', ownership_verified_at: Time.current)
  end
  let(:zone_id) { 'a' * 32 }
  let(:enabled_env) do
    {
      'LLA_CUSTOM_DOMAINS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_CLOUDFLARE_API_TOKEN_REF' => 'infisical://lla/dev/cloudflare#CLOUDFLARE_API_TOKEN',
      'LLA_CLOUDFLARE_ZONE_ID_REF' => 'infisical://lla/dev/cloudflare#CLOUDFLARE_ZONE_ID',
      'CLOUDFLARE_API_TOKEN' => 'token-value-1234567890',
      'CLOUDFLARE_ZONE_ID' => zone_id
    }
  end

  def consent!
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'cloudflare' => { 'enabled' => true, 'version' => 'v1', 'accepted_at' => 1.day.ago.iso8601 }
      }
    ))
  end

  it 'is not configured and performs zero egress by default' do
    expect(described_class.configured?).to be(false)
    expect { described_class.provision(domain) }
      .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
    expect(WebMock).not_to have_requested(:any, /cloudflare/)
  end

  it 'refuses to call the provider without account consent even when configured' do
    with_modified_env(enabled_env) do
      expect(described_class.configured?).to be(true)
      expect { described_class.provision(domain) }
        .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
    end
    expect(WebMock).not_to have_requested(:any, /cloudflare/)
  end

  it 'creates the hostname exactly once after an authoritative not-found' do
    consent!
    list = stub_request(:get, %r{/zones/#{zone_id}/custom_hostnames})
           .to_return(status: 200, body: { 'result' => [] }.to_json, headers: { 'Content-Type' => 'application/json' })
    create = stub_request(:post, %r{/zones/#{zone_id}/custom_hostnames})
             .to_return(status: 200,
                        body: { 'result' => { 'id' => 'cf-resource-1', 'ssl' => { 'status' => 'pending_validation' } } }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

    with_modified_env(enabled_env) do
      expect(described_class.provision(domain)).to eq({ resource_id: 'cf-resource-1', status: 'pending_validation' })
    end

    expect(list).to have_been_requested.once
    expect(create).to have_been_requested.once
  end

  it 'reuses an existing hostname instead of creating a duplicate' do
    consent!
    stub_request(:get, %r{/zones/#{zone_id}/custom_hostnames})
      .to_return(status: 200,
                 body: { 'result' => [{ 'id' => 'cf-existing', 'hostname' => 'docs.example.com',
                                        'ssl' => { 'status' => 'active' } }] }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
    create = stub_request(:post, %r{/zones/#{zone_id}/custom_hostnames})

    with_modified_env(enabled_env) do
      expect(described_class.provision(domain)).to eq({ resource_id: 'cf-existing', status: 'active' })
    end

    expect(create).not_to have_been_requested
  end

  it 'never creates a hostname when the lookup times out or fails with 5xx' do
    consent!
    create = stub_request(:post, %r{/zones/#{zone_id}/custom_hostnames})

    with_modified_env(enabled_env) do
      stub_request(:get, %r{/zones/#{zone_id}/custom_hostnames}).to_timeout
      expect { described_class.provision(domain) }.to raise_error(Lla::CustomDomains::ProviderErrors::Timeout)

      stub_request(:get, %r{/zones/#{zone_id}/custom_hostnames}).to_return(status: 503)
      expect { described_class.provision(domain) }.to raise_error(Lla::CustomDomains::ProviderErrors::ServerError)

      stub_request(:get, %r{/zones/#{zone_id}/custom_hostnames}).to_return(status: 401)
      expect { described_class.provision(domain) }.to raise_error(Lla::CustomDomains::ProviderErrors::Unauthorized)
    end

    expect(create).not_to have_been_requested
  end

  it 'treats an already deleted hostname as a successful teardown' do
    consent!
    stub_request(:delete, %r{/zones/#{zone_id}/custom_hostnames/cf-resource-1}).to_return(status: 404)

    with_modified_env(enabled_env) do
      expect(described_class.teardown('docs.example.com', 'cf-resource-1')).to be(true)
      expect(described_class.teardown('docs.example.com', nil)).to be(true)
    end
  end

  it 'refuses a provider resource id that is not an opaque token' do
    with_modified_env(enabled_env) do
      expect { described_class.teardown('docs.example.com', 'Bearer secret/../..') }
        .to raise_error(Lla::CustomDomains::ProviderErrors::ClientError)
    end
  end
end
