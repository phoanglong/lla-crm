# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::CustomDomains::Domain do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:other_account) { create(:account) }

  def build_domain(**overrides)
    described_class.new({ account_id: account.id, portal_id: portal.id,
                          hostname: 'docs.example.com', state: 'requested' }.merge(overrides))
  end

  describe 'application validation' do
    it 'rejects a portal from another tenant' do
      record = build_domain(account_id: other_account.id)

      expect(record).not_to be_valid
      expect(record.errors[:portal]).to include('must belong to the custom domain account')
    end

    it 'rejects a non-canonical hostname' do
      expect(build_domain(hostname: 'Docs.Example.com')).not_to be_valid
      expect(build_domain(hostname: 'docs.example.com:443')).not_to be_valid
    end

    it 'rejects a provider resource id without a provider' do
      record = build_domain(provider: 'none', provider_resource_id: 'cf-1')

      expect(record).not_to be_valid
      expect(record.errors[:provider_resource_id]).to include('requires a configured provider')
    end

    it 'rejects an unknown state or provider' do
      expect(build_domain(state: 'whatever')).not_to be_valid
      expect(build_domain(provider: 'route53')).not_to be_valid
    end
  end

  describe 'database constraints' do
    it 'enforces one lifecycle row per hostname' do
      build_domain.save!
      duplicate = build_domain(portal_id: create(:portal, account: account).id)

      expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'enforces one lifecycle row per portal' do
      build_domain.save!
      duplicate = build_domain(hostname: 'help.example.com')

      expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'rejects a non-canonical hostname at the database level' do
      expect { build_domain(hostname: 'DOCS.EXAMPLE.COM').save(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_hostname/)
    end

    it 'rejects an unknown state at the database level' do
      expect { build_domain(state: 'whatever').save(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_state/)
    end

    it 'refuses an active row that never proved ownership' do
      expect { build_domain(state: 'active').save(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_active/)
    end

    it 'refuses a partially written challenge' do
      expect { build_domain(challenge_id_digest: 'a' * 64).save(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_challenge/)
    end

    it 'refuses a provider resource id that looks like a credential' do
      expect { build_domain(provider: 'cloudflare', provider_resource_id: 'Bearer abc.def').save(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_provider_resource/)
    end

    it 'cascades to operations when the account is deleted' do
      domain = build_domain
      domain.save!
      Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'verify')

      expect { ActiveRecord::Base.connection.execute("DELETE FROM accounts WHERE id = #{account.id}") }
        .to change(Lla::CustomDomains::Operation, :count).to(0)
      expect(described_class.count).to eq(0)
    end
  end

  describe 'operation constraints' do
    it 'refuses attempts beyond the retry budget' do
      domain = build_domain
      domain.save!
      operation = Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'verify')

      expect { operation.update_columns(attempts: operation.max_attempts + 1) } # rubocop:disable Rails/SkipsModelValidations
        .to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domain_ops_attempts/)
    end

    it 'refuses a duplicate idempotency digest' do
      domain = build_domain
      domain.save!
      operation = Lla::CustomDomains::OperationService.enqueue!(domain: domain, operation_type: 'verify')
      clone = operation.dup

      expect { clone.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
