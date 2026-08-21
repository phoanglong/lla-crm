require 'rails_helper'

RSpec.describe Onboarding::HelpCenterArticleWriterJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, homepage_link: 'https://docs.example.com/') }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('writer-operation'),
      request_digest: Digest::SHA256.hexdigest('writer-request')
    )
  end
  let(:plan) do
    {
      allowed_urls: ['https://docs.example.com/start'],
      categories: [{ name: 'Start' }],
      articles: [{ title: 'Begin', category_name: 'Start', urls: ['https://docs.example.com/start'] }]
    }
  end
  let(:outbox) do
    Lla::Knowledge::GenerationStateService.new(operation).plan!(plan)
    operation.outboxes.sole
  end
  let(:built_article) { { title: 'Safe title', description: 'Summary', content: 'Safe body' } }

  before do
    builder = instance_double(Onboarding::HelpCenterArticleBuilder, perform: built_article)
    allow(Onboarding::HelpCenterArticleBuilder).to receive(:new).and_return(builder)
  end

  it 'creates exactly one draft and settles the durable item' do
    expect { described_class.perform_now(outbox.id) }
      .to change(portal.articles, :count).by(1)

    expect(operation.items.sole.reload).to have_attributes(state: 'succeeded', attempts: 1)
    expect(operation.items.sole.article).to be_draft
    expect(operation.reload).to have_attributes(state: 'completed', finished_items: 1)
  end

  it 'turns duplicate deliveries into a no-op instead of a second article' do
    described_class.perform_now(outbox.id)

    expect { described_class.perform_now(outbox.id) }
      .to not_change(portal.articles, :count)
      .and(not_change { operation.reload.finished_items })
  end

  it 'settles the item as failed when provider access is denied' do
    allow(Onboarding::HelpCenterArticleBuilder).to receive(:new).and_raise(Lla::Knowledge::ProviderPolicy::Denied)

    described_class.perform_now(outbox.id)

    expect(operation.items.sole.reload).to have_attributes(state: 'failed', last_error_code: 'provider_disabled')
    expect(operation.reload).to have_attributes(state: 'completed_with_errors', finished_items: 1, failed_items: 1)
  end

  it 'fails the operation without retrying an expired or forged encrypted payload' do
    outbox.update_column(:payload_ciphertext, 'f' * 40) # rubocop:disable Rails/SkipsModelValidations

    expect { described_class.perform_now(outbox.id) }.not_to raise_error

    expect(operation.reload).to have_attributes(state: 'failed', last_error_code: 'writer_payload_invalid')
    expect(operation.items.sole.reload.state).to eq('cancelled')
  end
end
