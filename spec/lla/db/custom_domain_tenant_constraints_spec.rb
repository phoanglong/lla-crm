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
end
