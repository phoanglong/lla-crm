# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::LifecycleService do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:other_portal) { create(:portal, account: create(:account)) }

  def domain_for(record)
    Lla::CustomDomains::Domain.find_by(portal_id: record.id)
  end

  describe '#request!' do
    it 'creates a tenant-bound domain waiting on an ownership proof' do
      domain = described_class.new(portal: portal).request!('Docs.Example.com.')

      expect(domain).to have_attributes(hostname: 'docs.example.com', state: 'ownership_pending',
                                        account_id: account.id, portal_id: portal.id, version: 1)
      expect(domain.challenge_active?).to be(true)
      expect(Lla::CustomDomains::Operation.where(custom_domain_id: domain.id, operation_type: 'verify').count).to eq(1)
    end

    it 'is idempotent for the same canonical host' do
      service = described_class.new(portal: portal)
      first = service.request!('docs.example.com')
      second = service.request!('DOCS.example.com')

      expect(second.id).to eq(first.id)
      expect(Lla::CustomDomains::Domain.count).to eq(1)
      expect(Lla::CustomDomains::Operation.where(operation_type: 'verify').count).to eq(1)
    end

    it 'refuses a hostname already registered by another tenant' do
      described_class.new(portal: portal).request!('docs.example.com')

      expect { described_class.new(portal: other_portal).request!('docs.example.com') }
        .to raise_error(described_class::Conflict, 'lla_custom_domain_taken')
      expect(Lla::CustomDomains::Domain.count).to eq(1)
    end

    it 'refuses to take over an active hostname held by another tenant' do
      domain = described_class.new(portal: portal).request!('docs.example.com')
      domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
      described_class.new(portal: portal).activate!(domain, resource_id: nil, status: 'local')

      expect { described_class.new(portal: other_portal).request!('docs.example.com.') }
        .to raise_error(described_class::Conflict)
      expect(domain.reload.portal_id).to eq(portal.id)
    end

    it 'rejects a malformed hostname without creating any state' do
      expect { described_class.new(portal: portal).request!("docs.example.com\r\n") }
        .to raise_error(Lla::CustomDomains::HostCanonicalizer::InvalidHost)
      expect(Lla::CustomDomains::Domain.count).to eq(0)
      expect(Lla::CustomDomains::Operation.count).to eq(0)
    end
  end

  describe 'repointing' do
    it 'schedules a teardown for the previous provider resource and resets ownership' do
      domain = described_class.new(portal: portal).request!('docs.example.com')
      domain.update!(state: 'provisioning', ownership_verified_at: Time.current, provider: 'cloudflare')
      described_class.new(portal: portal).activate!(domain, resource_id: 'cf-resource-1', status: 'active')

      described_class.new(portal: portal).request!('help.example.com')
      domain.reload

      expect(domain).to have_attributes(hostname: 'help.example.com', state: 'ownership_pending', version: 2,
                                        provider_resource_id: nil, ownership_verified_at: nil, activated_at: nil)
      teardown = Lla::CustomDomains::Operation.find_by(operation_type: 'remove', hostname: 'docs.example.com')
      expect(teardown).to have_attributes(custom_domain_id: nil, provider: 'cloudflare', provider_resource_id: 'cf-resource-1')
    end
  end

  describe '#release!' do
    it 'moves the domain to removing, revokes the challenge and enqueues teardown once' do
      domain = described_class.new(portal: portal).request!('docs.example.com')

      described_class.new(portal: portal).release!
      described_class.new(portal: portal).release!
      domain.reload

      expect(domain.state).to eq('removing')
      expect(domain.challenge_id_digest).to be_nil
      expect(Lla::CustomDomains::Operation.where(operation_type: 'remove').count).to eq(1)
    end
  end

  describe 'transitions' do
    it 'only advances ownership from ownership_pending and only activates from provisioning' do
      domain = described_class.new(portal: portal).request!('docs.example.com')
      service = described_class.new(portal: portal)

      expect(service.activate!(domain, resource_id: nil, status: 'local')).to be(false)
      expect(service.mark_ownership_verified!(domain)).to be(true)
      expect(domain.reload.state).to eq('provisioning')
      expect(service.mark_ownership_verified!(domain)).to be(false)
      expect(service.activate!(domain, resource_id: nil, status: 'local')).to be(true)
      expect(domain.reload).to have_attributes(state: 'active', challenge_id_digest: nil)
    end
  end
end
