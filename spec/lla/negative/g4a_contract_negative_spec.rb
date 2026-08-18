# frozen_string_literal: true

require 'rails_helper'

# The negative contract for wave G4a: seven statements that were each false at some
# point in this wave's history, and each of which would be a real production defect.
#
# Deliberately outside the 19-path focused suite, so that suite keeps its published
# count while this file is run — and counted — on its own, in either EE mode:
#
#   bundle exec rspec spec/lla/negative/g4a_contract_negative_spec.rb
#   DISABLE_ENTERPRISE=true bundle exec rspec spec/lla/negative/g4a_contract_negative_spec.rb
RSpec.describe 'Lla::CustomDomains negative contract' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:other_account) { create(:account) }
  let(:other_portal) { create(:portal, account: other_account) }
  let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
  let(:challenge) { Lla::CustomDomains::OwnershipChallenge }
  let(:operations) { Lla::CustomDomains::Operation }
  let(:tombstones) { Lla::CustomDomains::Tombstone }
  let(:domain) { lifecycle.request!('docs.example.com') }

  def execute(sql)
    ActiveRecord::Base.connection.execute(sql)
  end

  # Savepoint, so a statement the database aborts does not poison the example.
  def in_savepoint(&)
    ActiveRecord::Base.transaction(requires_new: true, &)
  end

  def insert_evidence(account_id:, portal_id:, source_portal_id:)
    execute(<<~SQL.squish)
      INSERT INTO lla_custom_domain_tombstones
        (account_id, portal_id, source_portal_id, reason, evidence_key, source_value_digest,
         source_value_preview, provider, state, created_at, updated_at)
      VALUES (#{account_id}, #{portal_id || 'NULL'}, #{source_portal_id}, 'legacy_hostname_unsupported',
              'legacy_hostname_unsupported:#{source_portal_id}:#{'a' * 32}', '#{'b' * 64}',
              'bad_host.example.com', 'none', 'manual_adoption_required', now(), now())
    SQL
  end

  def abandoned_teardown(resource_id, version)
    Lla::CustomDomains::OperationService.enqueue_teardown!(
      account_id: account.id, hostname: 'docs.example.com', provider: 'cloudflare',
      provider_resource_id: resource_id, domain_version: version
    )
  end

  # 1 — the worker/domain TOCTOU.
  it 'discards a verify result whose domain was released while the proof was in flight' do
    lease = Lla::CustomDomains::OperationService.claim!(
      operations.find_by!(custom_domain_id: domain.id, operation_type: 'verify')
    )
    allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify) do
      lifecycle.release!
      :verified
    end

    result = Lla::CustomDomains::OperationExecutor.new(lease).perform

    expect(result).to eq(:stale)
    expect(domain.reload).to have_attributes(state: 'removing', version: 2, ownership_verified_at: nil)
    expect(operations.find(lease.id).state).to eq('cancelled')
    expect(operations.where(operation_type: 'provision')).not_to exist
  end

  # 2 — a rejected legacy value is never dropped silently and never forced into a
  # routing key.
  it 'keeps a bounded, printable reference to a legacy value that cannot be a hostname' do
    raw = "bad host#{1.chr}.example.com"
    evidence = tombstones.create!(account_id: account.id, portal_id: portal.id, source_portal_id: portal.id,
                                  reason: 'legacy_hostname_unsupported', hostname: nil,
                                  source_value_digest: Digest::SHA256.hexdigest(raw),
                                  source_value_preview: tombstones.safe_preview(raw))

    expect(evidence.source_value_preview).to eq('bad_host?.example.com')
    expect(evidence.source_value_digest).to eq(Digest::SHA256.hexdigest(raw))
    expect(evidence.hostname).to be_nil
    # The same evidence without a way to identify what was lost is refused by
    # PostgreSQL, not merely by the model.
    expect do
      in_savepoint do
        execute(<<~SQL.squish)
          INSERT INTO lla_custom_domain_tombstones
            (account_id, source_portal_id, reason, evidence_key, provider, state, created_at, updated_at)
          VALUES (#{account.id}, #{portal.id}, 'legacy_hostname_unsupported',
                  'legacy_hostname_unsupported:#{portal.id}:#{'c' * 32}',
                  'none', 'manual_adoption_required', now(), now())
        SQL
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domain_tombstones_shape/)
  end

  # 3 — several portals in one account losing the same hostname are separate items.
  it 'records one outstanding item per portal for the same lost hostname' do
    owners = [portal, create(:portal, account: account), create(:portal, account: account)]
    owners.each do |owner|
      raw = "#{owner.id}-DOCS.example.com"
      tombstones.create!(account_id: account.id, portal_id: owner.id, source_portal_id: owner.id,
                         reason: 'legacy_hostname_duplicate', hostname: 'docs.example.com',
                         source_value_digest: Digest::SHA256.hexdigest(raw),
                         source_value_preview: tombstones.safe_preview(raw))
    end

    items = tombstones.outstanding.where(hostname: 'docs.example.com')

    expect(items.count).to eq(3)
    expect(items.pluck(:source_portal_id)).to match_array(owners.map(&:id))
    expect(items.pluck(:evidence_key).uniq.size).to eq(3)
  end

  # 4 — two rotations decided from the same snapshot must not both win.
  it 'lets exactly one of two concurrent rotations win and charges exactly one attempt' do
    domain
    first = Lla::CustomDomains::Domain.find(domain.id)
    second = Lla::CustomDomains::Domain.find(domain.id)

    winner = challenge.rotate!(first)

    expect { challenge.rotate!(second) }.to raise_error(challenge::Stale)
    expect(domain.reload.challenge_rotations).to eq(1)
    expect(challenge.resolve(domain, winner.id)).to eq(winner.body)
  end

  # 5 — a revoke decided before someone else rotated must not clear the replacement.
  it 'refuses to erase a challenge that replaced the one the revoker read' do
    domain
    stale_view = Lla::CustomDomains::Domain.find(domain.id)
    replacement = challenge.rotate!(domain.reload)

    revoked = challenge.revoke!(stale_view)

    expect(revoked).to be(false)
    expect(domain.reload.challenge_id_digest).to be_present
    expect(challenge.resolve(domain, replacement.id)).to eq(replacement.body)
  end

  # 6 — abandoned teardown evidence identifies the remote object, not the hostname.
  it 'opens a new item for a second remote resource on a hostname whose first item was resolved' do
    recorder = Lla::CustomDomains::TombstoneRecorder
    first_operation = abandoned_teardown('cf-resource-a', 1)
    first = recorder.record_abandoned_teardown!(first_operation)

    expect(recorder.record_abandoned_teardown!(first_operation)).to eq(first)

    first.resolve!(reference: 'ops-1')
    second = recorder.record_abandoned_teardown!(abandoned_teardown('cf-resource-b', 2))

    expect(second.id).not_to eq(first.id)
    expect(second).to have_attributes(state: 'manual_adoption_required', provider: 'cloudflare',
                                      provider_resource_id: 'cf-resource-b',
                                      provider_resource_digest: Digest::SHA256.hexdigest('cf-resource-b'))
    expect(second.evidence_key).not_to include('cf-resource-b')
    expect(tombstones.outstanding.where(hostname: 'docs.example.com').pluck(:id)).to eq([second.id])
  end

  # 7 — the tenant boundary is enforced by PostgreSQL, not by a model.
  it 'refuses evidence that binds one tenant account to another tenant portal' do
    # Materialised before the savepoints: a record first created inside a savepoint
    # that rolls back has its id restored to nil, and the next insert would then fail
    # for the wrong reason.
    [account, portal, other_account, other_portal].each(&:id)

    expect do
      in_savepoint { insert_evidence(account_id: account.id, portal_id: other_portal.id, source_portal_id: other_portal.id) }
    end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_lla_custom_domain_tombstones_portal_tenant/)
    expect do
      in_savepoint { insert_evidence(account_id: account.id, portal_id: other_portal.id, source_portal_id: portal.id) }
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domain_tombstones_portal/)
    expect do
      in_savepoint { insert_evidence(account_id: account.id, portal_id: portal.id, source_portal_id: portal.id) }
    end.to change(tombstones, :count).by(1)
  end
end
