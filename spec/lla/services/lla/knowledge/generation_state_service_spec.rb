require 'rails_helper'

RSpec.describe Lla::Knowledge::GenerationStateService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('state-operation'),
      request_digest: Digest::SHA256.hexdigest('state-request')
    )
  end
  let(:plan) do
    {
      allowed_urls: ['https://docs.example.com/start?tracking=yes', 'https://attacker.example/invented'],
      categories: [{ name: 'Getting Started', description: 'Setup help' }],
      articles: [
        {
          title: 'Start here', category_name: 'Getting Started',
          urls: ['https://docs.example.com/start?other=yes', 'https://attacker.example/invented']
        }
      ]
    }
  end

  it 'atomically stamps a bounded same-origin plan into durable items and encrypted outboxes' do
    described_class.new(operation).plan!(plan)

    item = operation.items.sole
    outbox = operation.outboxes.sole
    expect(operation.reload).to have_attributes(state: 'dispatching', expected_items: 1)
    expect(item.category).to have_attributes(name: 'Getting Started', account_id: account.id, portal_id: portal.id)
    expect(outbox.payload).to include(generation_item_id: item.id, urls: ['https://docs.example.com/start'])
  end

  it 'rolls back categories, items and outboxes when no article has approved provenance' do
    invalid_plan = plan.deep_dup
    invalid_plan[:articles].first[:urls] = ['https://attacker.example/invented']

    expect { described_class.new(operation).plan!(invalid_plan) }
      .to raise_error(described_class::InvalidPlan, 'lla_knowledge_plan_empty')
      .and not_change(operation.portal.categories, :count)
      .and not_change(operation.items, :count)
      .and not_change(operation.outboxes, :count)
  end

  it 'requires the exact item claim and creates one draft result under replay' do
    state = described_class.new(operation)
    state.plan!(plan)
    item = operation.items.sole
    state.claim_item!(item.id, token: 'owner-token')

    expect do
      state.complete_item!(
        item.id,
        token: 'owner-token',
        article_attributes: {
          title: 'Safe title', description: 'Summary', content: 'Safe body'
        }
      )
    end.to change(operation.portal.articles, :count).by(1)

    article = state.complete_item!(item.id, token: 'replay-token', article_attributes: { title: 'Ignored' })
    expect(article).to eq(item.reload.article)
    expect(article).to be_draft
    expect(operation.reload).to have_attributes(state: 'completed', finished_items: 1, failed_items: 0)
  end

  it 'rejects a forged claim without mutating the item or operation counters' do
    state = described_class.new(operation)
    state.plan!(plan)
    item = operation.items.sole
    state.claim_item!(item.id, token: 'owner-token')

    expect do
      state.complete_item!(item.id, token: 'forged-token', article_attributes: { title: 'Forged' })
    end.to raise_error(described_class::InvalidClaim)
      .and not_change(operation.portal.articles, :count)
      .and(not_change { operation.reload.finished_items })
  end

  it 'cancels unfinished work monotonically and records cancellation time' do
    state = described_class.new(operation)
    state.plan!(plan)

    state.terminalize!(state: 'cancelled', error_code: 'cancelled_by_user')
    state.terminalize!(state: 'failed', error_code: 'late_failure')

    expect(operation.reload).to have_attributes(state: 'cancelled', last_error_code: 'cancelled_by_user')
    expect(operation.cancelled_at).to be_present
    expect(operation.items.sole.state).to eq('cancelled')
    expect(operation.outboxes.sole.state).to eq('cancelled')
  end

  it 'scopes cancellation through the account association' do
    other_account = create(:account)

    expect do
      Lla::Knowledge::GenerationCancellationService.new(
        account: other_account, operation_id: operation.id
      ).perform
    end.to raise_error(ActiveRecord::RecordNotFound)
  end
end
