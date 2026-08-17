# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::Providers::CloudflareProvider do
  let(:account) { create(:account) }
  # Spy at the client boundary, not at HTTP: this proves the adapter never even
  # builds a request when a gate is closed.
  let(:client_calls) { %i[list_custom_hostnames create_custom_hostname delete_custom_hostname] }
  let(:portal) { create(:portal, account: account) }
  let(:client) { Lla::CustomDomains::Providers::CloudflareClient }
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

  def expect_no_client_traffic
    client_calls.each { |call| allow(client).to receive(call) }

    yield

    client_calls.each { |call| expect(client).not_to have_received(call) }
    expect(WebMock).not_to have_requested(:any, //)
  end

  describe 'account-aware gating' do
    it 'is unavailable and performs zero egress with every gate off' do
      expect(described_class.available_for?(account)).to be(false)

      expect_no_client_traffic do
        expect { described_class.provision(domain) }
          .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
        expect { described_class.check(domain) }
          .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
        expect { described_class.teardown('docs.example.com', 'cf-1', account: account) }
          .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
      end
    end

    it 'stays unavailable when only the account consent is missing' do
      with_modified_env(enabled_env) do
        expect(described_class.configured?).to be(true)
        expect(described_class.available_for?(account)).to be(false)

        expect_no_client_traffic do
          expect { described_class.provision(domain) }
            .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
          expect { described_class.teardown('docs.example.com', 'cf-1', account: account) }
            .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
        end
      end
    end

    it 'stays unavailable when only the secret reference is missing' do
      consent!

      with_modified_env(enabled_env.merge('LLA_CLOUDFLARE_API_TOKEN_REF' => nil)) do
        expect(described_class.available_for?(account)).to be(false)

        expect_no_client_traffic do
          expect { described_class.teardown('docs.example.com', 'cf-1', account: account) }
            .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
        end
      end
    end

    it 'stays unavailable without an account at all' do
      with_modified_env(enabled_env) do
        expect(described_class.available_for?(nil)).to be(false)

        expect_no_client_traffic do
          expect { described_class.teardown('docs.example.com', 'cf-1', account: nil) }
            .to raise_error(Lla::CustomDomains::ProviderErrors::NotConfigured)
        end
      end
    end

    it 'is never selected as the default provider until every gate is open' do
      with_modified_env(enabled_env) do
        expect(Lla::CustomDomains::ProviderRegistry.default_provider(account: account)).to eq('none')
      end

      consent!
      with_modified_env(enabled_env) do
        expect(Lla::CustomDomains::ProviderRegistry.default_provider(account: account)).to eq('cloudflare')
      end
    end
  end

  describe 'provisioning' do
    before { consent! }

    it 'creates the hostname exactly once after an authoritative not-found' do
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
  end

  describe 'teardown' do
    before { consent! }

    it 'treats an already deleted hostname as a successful teardown' do
      stub_request(:delete, %r{/zones/#{zone_id}/custom_hostnames/cf-resource-1}).to_return(status: 404)

      with_modified_env(enabled_env) do
        expect(described_class.teardown('docs.example.com', 'cf-resource-1', account: account)).to be(true)
        expect(described_class.teardown('docs.example.com', nil, account: account)).to be(true)
      end
    end

    it 'refuses a provider resource id that is not an opaque token' do
      with_modified_env(enabled_env) do
        expect { described_class.teardown('docs.example.com', 'Bearer secret/../..', account: account) }
          .to raise_error(Lla::CustomDomains::ProviderErrors::ClientError)
      end
    end
  end
end
