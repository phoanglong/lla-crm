require 'rails_helper'

RSpec.describe 'LLA knowledge generation database foundations', type: :model do
  let(:connection) { ActiveRecord::Base.connection }

  it 'persists tenant-bound operation, item, and encrypted outbox structures' do
    operation_columns = connection.columns(:lla_knowledge_generation_operations).index_by(&:name)
    item_columns = connection.columns(:lla_knowledge_generation_items).index_by(&:name)
    outbox_columns = connection.columns(:lla_knowledge_generation_outboxes).index_by(&:name)

    aggregate_failures do
      expect(operation_columns).to include(
        'account_id', 'portal_id', 'user_id', 'idempotency_digest',
        'consent_digest', 'provider_consent_digests'
      )
      expect(operation_columns).not_to include('website_content', 'email', 'raw_payload')
      expect(item_columns).to include('item_key_digest', 'source_digest', 'claim_digest')
      expect(outbox_columns).to include('payload_ciphertext', 'payload_digest', 'available_at')
      expect(outbox_columns).not_to include('payload', 'request_payload', 'response_payload')
    end
  end

  it 'enforces composite tenant foreign keys and idempotency below the model layer' do
    operation_fks = connection.foreign_keys(:lla_knowledge_generation_operations).index_by(&:name)
    item_fks = connection.foreign_keys(:lla_knowledge_generation_items).index_by(&:name)
    outbox_fks = connection.foreign_keys(:lla_knowledge_generation_outboxes).index_by(&:name)
    operation_indexes = connection.indexes(:lla_knowledge_generation_operations).index_by(&:name)
    item_indexes = connection.indexes(:lla_knowledge_generation_items).index_by(&:name)

    aggregate_failures do
      expect(operation_fks).to include('fk_lla_knowledge_operations_portal_tenant',
                                       'fk_lla_knowledge_operations_membership')
      expect(item_fks).to include('fk_lla_knowledge_items_operation_tenant')
      expect(outbox_fks).to include('fk_lla_knowledge_outboxes_operation_tenant')
      expect(operation_indexes.fetch('idx_lla_knowledge_operations_idempotency')).to have_attributes(unique: true)
      expect(item_indexes.fetch('idx_lla_knowledge_items_article_result')).to have_attributes(
        unique: true, columns: ['article_id']
      )
    end
  end

  it 'rejects a forged cross-tenant portal below the model layer' do
    account = create(:account)
    user = create(:user, account: account)
    other_portal = create(:portal, account: create(:account))
    now = Time.current
    forged_row = {
      account_id: account.id,
      portal_id: other_portal.id,
      user_id: user.id,
      operation_type: 'onboarding',
      state: 'pending',
      idempotency_digest: Digest::SHA256.hexdigest('forged-operation'),
      request_digest: Digest::SHA256.hexdigest('forged-request'),
      version: 1,
      expected_items: 0,
      finished_items: 0,
      failed_items: 0,
      max_items: 25,
      max_source_urls: 75,
      max_attempts: 3,
      expires_at: 1.day.from_now,
      created_at: now,
      updated_at: now
    }

    expect do
      # Intentionally bypass the model to prove the database tenant FK.
      Lla::Knowledge::GenerationOperation.insert_all!([forged_row]) # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it 'enforces digest, counter, state, and retry bounds' do
    operation_checks = connection.check_constraints(:lla_knowledge_generation_operations).index_by(&:name)
    item_checks = connection.check_constraints(:lla_knowledge_generation_items).index_by(&:name)
    outbox_checks = connection.check_constraints(:lla_knowledge_generation_outboxes).index_by(&:name)

    aggregate_failures do
      expect(operation_checks).to include('chk_lla_knowledge_operations_digests',
                                          'chk_lla_knowledge_operations_bounds',
                                          'chk_lla_knowledge_operations_state',
                                          'chk_lla_knowledge_operations_provider_consents')
      expect(item_checks).to include('chk_lla_knowledge_items_digests', 'chk_lla_knowledge_items_bounds',
                                     'chk_lla_knowledge_items_result_state')
      expect(outbox_checks).to include('chk_lla_knowledge_outboxes_digests',
                                       'chk_lla_knowledge_outboxes_attempts',
                                       'chk_lla_knowledge_outboxes_payload')
    end
  end

  it 'rejects non-object provider consent evidence below the model layer' do
    operation = Lla::Knowledge::GenerationOperation.create!(
      account: (account = create(:account)),
      portal: create(:portal, account: account),
      user: create(:user, account: account),
      idempotency_digest: Digest::SHA256.hexdigest('provider-consent-operation'),
      request_digest: Digest::SHA256.hexdigest('provider-consent-request')
    )

    expect do
      operation.update_column(:provider_consent_digests, []) # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /provider_consents/)
  end

  it 'rejects a succeeded item without a durable article result below the model layer' do
    account = create(:account)
    portal = create(:portal, account: account, homepage_link: 'https://docs.example.com/')
    operation = Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: create(:user, account: account),
      idempotency_digest: Digest::SHA256.hexdigest('result-operation'),
      request_digest: Digest::SHA256.hexdigest('result-request')
    )
    Lla::Knowledge::GenerationStateService.new(operation).plan!(
      allowed_urls: ['https://docs.example.com/start'],
      categories: [{ name: 'Start' }],
      articles: [{ category_name: 'Start', urls: ['https://docs.example.com/start'] }]
    )

    expect do
      operation.items.sole.update_column(:state, 'succeeded') # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid, /result_state/)
  end
end
