# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::HostResolver do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:domain) { Lla::CustomDomains::LifecycleService.new(portal: portal).request!('docs.example.com') }

  def activate!(record)
    record.update!(state: 'provisioning', ownership_verified_at: Time.current)
    Lla::CustomDomains::LifecycleService.new(portal: portal).activate!(record, resource_id: nil, status: 'local')
    record.reload
  end

  it 'resolves only an active lifecycle row, and canonicalises the Host first' do
    activate!(domain)

    expect(described_class.portal_for('DOCS.example.com.')).to eq(portal)
    expect(described_class.portal_for('docs.example.com')).to eq(portal)
  end

  it 'does not resolve a domain that is not active yet' do
    expect(domain.state).to eq('ownership_pending')
    expect(described_class.portal_for('docs.example.com')).to be_nil
  end

  it 'stops resolving while the domain is being removed' do
    activate!(domain)
    Lla::CustomDomains::LifecycleService.new(portal: portal).release!

    expect(described_class.portal_for('docs.example.com')).to be_nil
  end

  it 'does not resolve an archived portal' do
    activate!(domain)
    portal.update!(archived: true)

    expect(described_class.portal_for('docs.example.com')).to be_nil
  end

  it 'returns nothing for malformed, hostile or unknown hosts' do
    activate!(domain)

    ["docs.example.com\r\nX-Injected: 1", 'docs.example.com:443', 'admin@docs.example.com',
     '127.0.0.1', 'unknown.example.com', '', nil].each do |host|
      expect(described_class.portal_for(host)).to be_nil
    end
  end

  it 'never treats an installation host as a custom domain' do
    activate!(domain)

    with_modified_env('FRONTEND_URL' => 'https://docs.example.com') do
      expect(described_class.portal_for('docs.example.com')).to be_nil
    end
  end
end
