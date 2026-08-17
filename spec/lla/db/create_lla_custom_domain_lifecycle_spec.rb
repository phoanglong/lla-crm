# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260817180000_create_lla_custom_domain_lifecycle.rb')

# The legacy backfill is data migration, so it gets data tests: what it imports,
# what it refuses to import, what it records as evidence and what it leaves alone.
RSpec.describe CreateLlaCustomDomainLifecycle do
  let(:account) { create(:account) }
  let(:migration) { described_class.new.tap { |instance| instance.verbose = false } }

  def backfill!
    Lla::CustomDomains::Domain.delete_all
    migration.send(:backfill_custom_domains)
  end

  def set_raw_domain(portal, value)
    ActiveRecord::Base.connection.execute(
      "UPDATE portals SET custom_domain = #{ActiveRecord::Base.connection.quote(value)} WHERE id = #{portal.id}"
    )
  end

  def set_ssl_settings(portal, settings)
    ActiveRecord::Base.connection.execute(
      "UPDATE portals SET ssl_settings = #{ActiveRecord::Base.connection.quote(settings.to_json)}::jsonb WHERE id = #{portal.id}"
    )
  end

  it 'imports a canonical legacy hostname as an honest legacy row' do
    portal = create(:portal, account: account, custom_domain: 'docs.example.com')

    backfill!
    domain = Lla::CustomDomains::Domain.find_by(portal_id: portal.id)

    expect(domain).to have_attributes(
      hostname: 'docs.example.com', state: 'active', ownership_source: 'legacy_import',
      reverify_required: true, ownership_verified_at: nil, activated_at: nil, provider: 'none'
    )
  end

  it 'canonicalises through the runtime canonicalizer instead of a looser regexp' do
    portal = create(:portal, account: account)
    set_raw_domain(portal, 'DOCS.Example.com.')

    backfill!

    expect(Lla::CustomDomains::Domain.find_by(portal_id: portal.id).hostname).to eq('docs.example.com')
  end

  it 'refuses a hostname the runtime would reject' do
    long_label = "#{'a' * 64}.example.com"
    reserved = 'helpdesk.localhost'
    ip_literal = '203.0.113.10'

    [long_label, reserved, ip_literal].each do |value|
      portal = create(:portal, account: account)
      set_raw_domain(portal, value)
    end

    backfill!

    expect(Lla::CustomDomains::Domain.count).to eq(0)
    [long_label, reserved, ip_literal].each do |value|
      expect(Lla::CustomDomains::HostCanonicalizer.canonicalize(value)).to be_nil
    end
  end

  it 'carries the only legacy evidence that exists across as provider status' do
    portal = create(:portal, account: account, custom_domain: 'docs.example.com')
    set_ssl_settings(portal, 'cf_status' => 'active', 'cf_verification_body' => 'proof')

    backfill!

    expect(Lla::CustomDomains::Domain.find_by(portal_id: portal.id).provider_status).to eq('active')
  end

  it 'leaves portals.ssl_settings byte-for-byte alone, including unrelated keys' do
    portal = create(:portal, account: account, custom_domain: 'docs.example.com')
    settings = {
      'cf_status' => 'active', 'cf_verification_id' => 'legacy-id', 'cf_verification_body' => 'proof',
      'operator_note' => 'do not delete', 'custom' => { 'nested' => [1, 2, 3] }
    }
    set_ssl_settings(portal, settings)

    backfill!

    expect(portal.reload.ssl_settings).to eq(settings)
  end

  it 'imports each hostname once when two portals collide after canonicalisation' do
    first = create(:portal, account: account)
    second = create(:portal, account: account)
    set_raw_domain(first, 'docs.example.com')
    set_raw_domain(second, 'DOCS.example.com')

    backfill!

    expect(Lla::CustomDomains::Domain.count).to eq(1)
    expect(Lla::CustomDomains::Domain.first.portal_id).to eq(first.id)
  end

  it 'keeps a legacy row resolvable for public host lookup' do
    portal = create(:portal, account: account, custom_domain: 'docs.example.com')

    backfill!

    expect(Lla::CustomDomains::HostResolver.portal_for('docs.example.com')).to eq(portal)
  end
end
