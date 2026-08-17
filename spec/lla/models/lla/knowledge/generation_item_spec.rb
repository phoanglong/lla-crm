require 'rails_helper'

RSpec.describe Lla::Knowledge::GenerationItem do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account) }
  let(:operation) do
    Lla::Knowledge::GenerationOperation.create!(
      account: account,
      portal: portal,
      user: user,
      idempotency_digest: Digest::SHA256.hexdigest('operation'),
      request_digest: Digest::SHA256.hexdigest('request')
    )
  end

  def build_item(overrides = {})
    described_class.new(
      {
        operation: operation,
        account: account,
        portal: portal,
        ordinal: 0,
        item_key_digest: Digest::SHA256.hexdigest('item'),
        source_digest: Digest::SHA256.hexdigest('source')
      }.merge(overrides)
    )
  end

  it 'accepts an item owned by the operation tenant and portal' do
    expect(build_item).to be_valid
  end

  it 'rejects a category from another portal' do
    other_portal = create(:portal, account: account)
    category = create(:category, portal: other_portal, account: account)

    item = build_item(category: category)

    expect(item).not_to be_valid
    expect(item.errors[:category]).to include('must belong to the item tenant and portal')
  end

  it 'rejects an operation from another tenant even when ids are forged' do
    other_account = create(:account)
    other_operation = Lla::Knowledge::GenerationOperation.create!(
      account: other_account,
      portal: create(:portal, account: other_account),
      user: create(:user, account: other_account),
      idempotency_digest: Digest::SHA256.hexdigest('other-operation'),
      request_digest: Digest::SHA256.hexdigest('other-request')
    )

    item = build_item(operation: other_operation)

    expect(item).not_to be_valid
    expect(item.errors[:operation]).to include('must share the item tenant and portal')
  end

  it 'requires the result column that belongs to the item type' do
    generated = build_item(state: 'succeeded', item_type: 'article_generation')
    translation = build_item(state: 'succeeded', item_type: 'translation')
    reindex = build_item(state: 'succeeded', item_type: 'reindex')

    expect(generated).not_to be_valid
    expect(translation).not_to be_valid
    expect(reindex).to be_valid
  end

  it 'accepts a translated result only through output_article' do
    translated_article = create(:article, account: account, portal: portal)
    item = build_item(state: 'succeeded', item_type: 'translation', output_article: translated_article)

    expect(item).to be_valid
  end
end
