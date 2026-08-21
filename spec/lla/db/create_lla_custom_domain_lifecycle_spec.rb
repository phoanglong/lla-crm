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
    Lla::CustomDomains::Tombstone.delete_all
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

  # Refusing is correct; refusing *silently* is not. A legacy hostname that stops
  # routing at this migration has to leave an operator work list behind, naming the
  # portal and the exact value that could not be represented.
  it 'records durable evidence for every legacy hostname it drops' do
    unsupported = create(:portal, account: account)
    set_raw_domain(unsupported, 'help.acme.local')

    backfill!

    expect(Lla::CustomDomains::Tombstone.outstanding.find_by(portal_id: unsupported.id))
      .to have_attributes(hostname: nil, reason: 'legacy_hostname_unsupported',
                          account_id: account.id, provider: 'none',
                          source_value_preview: 'help.acme.local',
                          source_value_digest: Digest::SHA256.hexdigest('help.acme.local'))
    expect(unsupported.reload.custom_domain).to eq('help.acme.local')
  end

  # The value cannot go into a routing-key column, and that is exactly why the
  # evidence carries a printable preview and the digest of the original bytes: an
  # operator can still tell which portal to fix and recognise what was there.
  it 'records evidence for values a hostname column could never hold' do
    cases = {
      'bad host.example.com' => 'bad_host.example.com',
      "ctrl\u0001host.example.com" => 'ctrl?host.example.com',
      "#{'a' * 300}.example.com" => "#{'a' * 200}...+112",
      '-malformed-.example.com' => '-malformed-.example.com'
    }
    portals = cases.keys.index_with { |raw| create(:portal, account: account).tap { |p| set_raw_domain(p, raw) } }

    backfill!

    expect(Lla::CustomDomains::Domain.count).to eq(0)
    cases.each do |raw, preview|
      evidence = Lla::CustomDomains::Tombstone.find_by!(portal_id: portals[raw].id)
      expect(evidence).to have_attributes(reason: 'legacy_hostname_unsupported', hostname: nil,
                                          source_value_preview: preview,
                                          source_value_digest: Digest::SHA256.hexdigest(raw))
      expect(portals[raw].reload.custom_domain).to eq(raw)
    end
  end

  # Every portal that loses a hostname is its own item on the work list: collapsing
  # them into one row by hostname would hide all but the first.
  it 'keeps one evidence item per portal when several collapse onto one hostname' do
    keeper = create(:portal, account: account)
    losers = Array.new(3) { create(:portal, account: account) }
    set_raw_domain(keeper, 'docs.example.com')
    ['DOCS.example.com', 'docs.example.com.', 'Docs.Example.COM'].each_with_index do |raw, index|
      set_raw_domain(losers[index], raw)
    end

    backfill!

    expect(Lla::CustomDomains::Domain.pluck(:portal_id)).to eq([keeper.id])
    evidence = Lla::CustomDomains::Tombstone.outstanding.where(portal_id: losers.map(&:id))
    expect(evidence.count).to eq(3)
    expect(evidence.pluck(:reason).uniq).to eq(['legacy_hostname_duplicate'])
    expect(evidence.pluck(:hostname).uniq).to eq(['docs.example.com'])
    expect(evidence.pluck(:evidence_key).uniq.size).to eq(3)
  end

  it 'keeps the accounts apart and still records the one that loses the global hostname' do
    other_account = create(:account)
    first = create(:portal, account: account)
    second = create(:portal, account: other_account)
    set_raw_domain(first, 'docs.example.com')
    set_raw_domain(second, 'DOCS.example.com')

    backfill!

    expect(Lla::CustomDomains::Domain.pluck(:account_id, :portal_id)).to eq([[account.id, first.id]])
    expect(Lla::CustomDomains::Tombstone.outstanding.find_by(portal_id: second.id))
      .to have_attributes(account_id: other_account.id, reason: 'legacy_hostname_duplicate',
                          hostname: 'docs.example.com')
  end

  it 'is idempotent: re-running the backfill adds no second copy of any evidence' do
    keeper = create(:portal, account: account)
    loser = create(:portal, account: account)
    unsupported = create(:portal, account: account)
    set_raw_domain(keeper, 'docs.example.com')
    set_raw_domain(loser, 'DOCS.example.com')
    set_raw_domain(unsupported, 'bad host.example.com')

    backfill!
    before = Lla::CustomDomains::Tombstone.order(:id).pluck(:evidence_key)
    migration.send(:backfill_custom_domains)

    expect(Lla::CustomDomains::Tombstone.order(:id).pluck(:evidence_key)).to eq(before)
    expect(before.size).to eq(2)
  end

  it 'survives a legacy cf_status that is not a string' do
    portal = create(:portal, account: account, custom_domain: 'docs.example.com')
    set_ssl_settings(portal, 'cf_status' => 404)

    expect { backfill! }.not_to raise_error
    expect(Lla::CustomDomains::Domain.find_by(portal_id: portal.id).provider_status).to eq('404')
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
