# frozen_string_literal: true

require 'rails_helper'

# Database-level negative evidence. Every statement here bypasses ActiveRecord
# validation on purpose: the point is that the schema itself refuses the write.
RSpec.describe 'LLA custom-domain database invariants' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:other_portal) { create(:portal, account: other_account) }

  def execute(sql)
    ActiveRecord::Base.connection.execute(sql)
  end

  def insert_domain(account_id:, portal_id:, hostname: 'docs.example.com', state: 'requested', extra: '')
    execute(<<~SQL.squish)
      INSERT INTO lla_custom_domains
        (account_id, portal_id, hostname, state, version, provider, ownership_source,
         reverify_required, challenge_rotations, created_at, updated_at#{extra.present? ? ", #{extra.split('=').first}" : ''})
      VALUES (#{account_id}, #{portal_id}, '#{hostname}', '#{state}', 1, 'none', 'nonce_challenge',
              FALSE, 0, now(), now()#{extra.present? ? ", #{extra.split('=').last}" : ''})
    SQL
  end

  describe 'domain tenant key' do
    it 'refuses a domain whose account does not own the portal' do
      # Savepoint so the aborted statement does not poison the example's transaction.
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          insert_domain(account_id: other_account.id, portal_id: portal.id)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_lla_custom_domains_portal_tenant/)

      expect(Lla::CustomDomains::Domain.count).to eq(0)
    end

    it 'accepts the matching tenant pair' do
      expect { insert_domain(account_id: account.id, portal_id: portal.id) }.not_to raise_error
    end

    it 'refuses an active row that carries no proof and no legacy marker' do
      expect { insert_domain(account_id: account.id, portal_id: portal.id, state: 'active') }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_active/)
    end

    it 'refuses a removing row without a removal timestamp' do
      expect { insert_domain(account_id: account.id, portal_id: portal.id, state: 'removing') }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_removing/)
    end

    it 'refuses an unknown ownership source' do
      expect do
        execute(<<~SQL.squish)
          INSERT INTO lla_custom_domains
            (account_id, portal_id, hostname, state, version, provider, ownership_source,
             reverify_required, challenge_rotations, created_at, updated_at)
          VALUES (#{account.id}, #{portal.id}, 'docs.example.com', 'requested', 1, 'none', 'trust_me',
                  FALSE, 0, now(), now())
        SQL
      end.to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_ownership_source/)
    end
  end

  describe 'operation tenant key' do
    let(:domain) { Lla::CustomDomains::LifecycleService.new(portal: portal).request!('docs.example.com') }

    def insert_operation(account_id:, custom_domain_id:, state: 'pending', claim: {})
      claim_digest = claim.fetch(:digest, 'NULL')
      claimed_at = claim.fetch(:claimed_at, 'NULL')
      completed_at = claim.fetch(:completed_at, 'NULL')
      execute(<<~SQL.squish)
        INSERT INTO lla_custom_domain_operations
          (account_id, custom_domain_id, operation_type, state, idempotency_digest, request_digest,
           claim_digest, hostname, provider, domain_version, attempts, max_attempts, deferrals,
           available_at, claimed_at, completed_at, expires_at, created_at, updated_at)
        VALUES (#{account_id}, #{custom_domain_id || 'NULL'}, 'verify', '#{state}', '#{'a' * 64}', '#{'b' * 64}',
                #{claim_digest}, 'docs.example.com', 'none', 1, 0, 5, 0,
                now(), #{claimed_at}, #{completed_at}, now() + interval '30 days', now(), now())
      SQL
    end

    it 'refuses an operation pointing at another tenant domain' do
      target = domain

      expect { insert_operation(account_id: other_account.id, custom_domain_id: target.id) }
        .to raise_error(ActiveRecord::InvalidForeignKey, /fk_lla_custom_domain_ops_domain_tenant/)
    end

    it 'accepts the matching tenant pair and a tenant-only teardown snapshot' do
      target = domain
      Lla::CustomDomains::Operation.delete_all

      expect { insert_operation(account_id: account.id, custom_domain_id: target.id) }.not_to raise_error
      expect { insert_operation(account_id: account.id, custom_domain_id: nil) }
        .to raise_error(ActiveRecord::RecordNotUnique) # same idempotency digest, different shape
    end

    it 'refuses a claimed row without a claim' do
      target = domain

      expect { insert_operation(account_id: account.id, custom_domain_id: target.id, state: 'claimed') }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domain_ops_claim_state/)
    end

    it 'refuses a waiting row that still carries a claim' do
      target = domain

      expect do
        insert_operation(account_id: account.id, custom_domain_id: target.id, state: 'deferred',
                         claim: { digest: "'#{'c' * 64}'", claimed_at: 'now()' })
      end.to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domain_ops_claim_state/)
    end

    it 'refuses a terminal row without a completion timestamp' do
      target = domain

      expect { insert_operation(account_id: account.id, custom_domain_id: target.id, state: 'succeeded') }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domain_ops_claim_state/)
    end

    it 'keeps a teardown snapshot alive after the domain row is deleted' do
      target = domain
      Lla::CustomDomains::OperationService.enqueue_teardown!(
        account_id: account.id, hostname: target.hostname, provider: 'cloudflare',
        provider_resource_id: 'cf-1', domain_version: target.version
      )
      snapshot = Lla::CustomDomains::Operation.find_by!(operation_type: 'remove')

      target.destroy!

      expect(snapshot.reload).to be_present
      expect(snapshot.custom_domain_id).to be_nil
    end
  end

  describe 'cross-tenant hostname claim' do
    it 'cannot be created for a second tenant even by direct insert' do
      Lla::CustomDomains::LifecycleService.new(portal: portal).request!('docs.example.com')

      expect { insert_domain(account_id: other_account.id, portal_id: other_portal.id) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  # The evidence table is what an operator works from after the migration drops a
  # legacy value, so the schema itself refuses evidence nobody could act on.
  describe 'tombstone evidence' do
    # Materialised before the savepoints below: a record created inside a savepoint
    # that rolls back has its id restored to nil, which would make the next insert
    # fail for the wrong reason.
    before do
      account
      portal
    end

    def insert_tombstone(columns)
      defaults = { account_id: account.id, reason: 'legacy_hostname_unsupported',
                   evidence_key: "legacy_hostname_unsupported:#{portal.id}:#{'a' * 32}",
                   portal_id: portal.id, source_value_digest: 'b' * 64,
                   source_value_preview: 'bad_host.example.com', provider: 'none',
                   state: 'manual_adoption_required' }
      values = defaults.merge(columns)
      keys = values.keys.join(', ')
      literals = values.values.map { |value| ActiveRecord::Base.connection.quote(value) }.join(', ')
      execute("INSERT INTO lla_custom_domain_tombstones (#{keys}, created_at, updated_at) " \
              "VALUES (#{literals}, now(), now())")
    end

    def expect_refusal(columns, constraint)
      expect do
        ActiveRecord::Base.transaction(requires_new: true) { insert_tombstone(columns) }
      end.to raise_error(ActiveRecord::StatementInvalid, /#{constraint}/)
    end

    it 'accepts one item per portal for the same lost hostname' do
      second_portal = create(:portal, account: account)

      expect do
        insert_tombstone(reason: 'legacy_hostname_duplicate', hostname: 'docs.example.com',
                         evidence_key: "legacy_hostname_duplicate:#{portal.id}:#{'a' * 32}")
        insert_tombstone(reason: 'legacy_hostname_duplicate', hostname: 'docs.example.com',
                         portal_id: second_portal.id,
                         evidence_key: "legacy_hostname_duplicate:#{second_portal.id}:#{'c' * 32}")
      end.to change(Lla::CustomDomains::Tombstone, :count).by(2)
    end

    it 'refuses a second copy of the same evidence item' do
      insert_tombstone({})

      expect { insert_tombstone(source_value_digest: 'c' * 64) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'refuses a dropped legacy value that names no portal or no original' do
      expect_refusal({ portal_id: nil }, 'chk_lla_custom_domain_tombstones_shape')
      expect_refusal({ source_value_digest: nil }, 'chk_lla_custom_domain_tombstones_shape')
      expect_refusal({ source_value_preview: nil }, 'chk_lla_custom_domain_tombstones_shape')
    end

    it 'refuses remote-resource evidence with no hostname to act on' do
      expect_refusal({ reason: 'provider_teardown_abandoned', hostname: nil, portal_id: nil,
                       source_value_digest: nil, source_value_preview: nil,
                       evidence_key: "provider_teardown_abandoned:0:#{'a' * 32}" },
                     'chk_lla_custom_domain_tombstones_resource')
    end

    it 'refuses an unsafe value in the hostname column and in the preview' do
      expect_refusal({ hostname: 'bad host.example.com' }, 'chk_lla_custom_domain_tombstones_hostname')
      expect_refusal({ source_value_preview: "ctrl\u0001host" }, 'chk_lla_custom_domain_tombstones_evidence')
      expect_refusal({ source_value_digest: 'not-a-digest' }, 'chk_lla_custom_domain_tombstones_evidence')
      expect_refusal({ evidence_key: 'Has Spaces And Caps' }, 'chk_lla_custom_domain_tombstones_evidence')
    end
  end
end
