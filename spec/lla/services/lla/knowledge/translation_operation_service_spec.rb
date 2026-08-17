require 'rails_helper'

RSpec.describe Lla::Knowledge::TranslationOperationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:portal) { create(:portal, account: account, config: { allowed_locales: %w[en es] }) }
  let(:category) { create(:category, account: account, portal: portal, locale: 'es') }
  let(:article) { create(:article, account: account, portal: portal, locale: 'en') }
  let(:arguments) do
    {
      account: account,
      portal: portal,
      user: user,
      articles: [article],
      target_locale: 'es',
      target_category: category,
      force: false,
      idempotency_key: 'translation:request-123'
    }
  end

  around do |example|
    account.enable_features!('captain_tasks')
    account.update!(custom_attributes: account.custom_attributes.merge(
      'lla_provider_consents' => {
        'openai' => { 'enabled' => true, 'version' => '2026-08-17', 'accepted_at' => Time.current.iso8601 }
      }
    ))
    with_modified_env(
      'LLA_KNOWLEDGE_EXTERNAL_EGRESS_ENABLED' => 'true',
      'LLA_KNOWLEDGE_ARTICLE_TRANSLATION_ENABLED' => 'true'
    ) { example.run }
  end

  it 'atomically persists a tenant-bound operation, item and encrypted outbox' do
    operation = described_class.new(**arguments).perform

    expect(operation).to have_attributes(
      account_id: account.id, portal_id: portal.id, user_id: user.id,
      operation_type: 'translation', expected_items: 1
    )
    expect(operation.items.sole).to have_attributes(
      account_id: account.id, portal_id: portal.id, category_id: category.id,
      item_type: 'translation', source_digest: Lla::Knowledge::ArticleSearchDocument.digest(article)
    )
    expect(operation.outboxes.sole).to have_attributes(event_type: 'translate_article')
    expect(operation.outboxes.sole.payload).to include(source_article_id: article.id, target_locale: 'es', force: false)
  end

  it 'returns the same durable operation for an exact replay' do
    first = described_class.new(**arguments).perform
    replay = described_class.new(**arguments).perform

    expect(replay.id).to eq(first.id)
    expect(first.items.count).to eq(1)
    expect(first.outboxes.count).to eq(1)
  end

  it 'rejects idempotency-key reuse with changed request content' do
    described_class.new(**arguments).perform

    expect do
      described_class.new(**arguments, force: true).perform
    end.to raise_error(described_class::Conflict, 'lla_knowledge_idempotency_conflict')
  end

  it 'rejects cross-tenant articles and category before persistence' do
    other_account = create(:account)
    other_portal = create(:portal, account: other_account, config: { allowed_locales: %w[en es] })
    forged_article = create(:article, account: other_account, portal: other_portal, locale: 'en')

    expect do
      described_class.new(**arguments, articles: [forged_article]).perform
    end.to raise_error(described_class::InvalidRequest)
      .and not_change(Lla::Knowledge::GenerationOperation, :count)
  end

  it 'requires an administrator, feature entitlement and provider consent' do
    agent = create(:user, account: account)
    account.update!(custom_attributes: account.custom_attributes.except('lla_provider_consents'))

    expect { described_class.new(**arguments, user: agent).perform }
      .to raise_error(described_class::InvalidRequest, 'translation user must be an administrator')
      .and not_change(Lla::Knowledge::GenerationOperation, :count)

    expect { described_class.new(**arguments).perform }
      .to raise_error(Lla::Knowledge::ProviderPolicy::Denied)
      .and not_change(Lla::Knowledge::GenerationOperation, :count)
  end
end
