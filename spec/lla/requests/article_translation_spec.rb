require 'rails_helper'

RSpec.describe 'LLA article translation operations', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:portal) { create(:portal, account: account, config: { allowed_locales: %w[en es] }) }
  let(:source_category) { create(:category, portal: portal, account: account, locale: 'en') }
  let(:target_category) { create(:category, portal: portal, account: account, locale: 'es') }
  let(:article) do
    create(:article, category: source_category, portal: portal, account: account, author: admin, locale: 'en')
  end
  let(:url) { "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/articles/bulk_actions/translate" }
  let(:params) { { ids: [article.id], locale: 'es', category_id: target_category.id } }

  around do |example|
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

  before { clear_enqueued_jobs }

  it 'requires authentication and administrator authorization' do
    post url, params: params, as: :json
    expect(response).to have_http_status(:unauthorized)

    account.enable_features!('captain_tasks')
    post url, headers: agent.create_new_auth_token, params: params, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(Lla::Knowledge::GenerationOperation).not_to exist
  end

  it 'accepts one durable operation and exposes only its public identifier' do
    account.enable_features!('captain_tasks')

    expect do
      post url,
           headers: admin.create_new_auth_token.merge('Idempotency-Key' => 'translation:request-123'),
           params: params,
           as: :json
    end.to have_enqueued_job(Lla::Knowledge::GenerationOutboxDispatchJob).exactly(:once)

    expect(response).to have_http_status(:ok)
    operation = Lla::Knowledge::GenerationOperation.sole
    expect(response.headers['X-LLA-Knowledge-Operation-Id']).to eq(operation.id.to_s)
    expect(operation.items.count).to eq(1)
    expect(operation.outboxes.count).to eq(1)
  end

  it 'rejects a mixed valid and cross-portal id list atomically' do
    account.enable_features!('captain_tasks')
    other_account = create(:account)
    forged = create(:article, account: other_account, portal: create(:portal, account: other_account))

    expect do
      post url,
           headers: admin.create_new_auth_token,
           params: params.merge(ids: [article.id, forged.id]),
           as: :json
    end.not_to change(Lla::Knowledge::GenerationOperation, :count)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'reports duplicate translations without scheduling provider work unless force is explicit' do
    account.enable_features!('captain_tasks')
    existing = create(
      :article,
      account: account,
      portal: portal,
      category: target_category,
      locale: 'es',
      associated_article_id: article.id
    )

    post url, headers: admin.create_new_auth_token, params: params, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['duplicate_articles']).to contain_exactly(include('id' => existing.id))
    expect(Lla::Knowledge::GenerationOperation).not_to exist

    post url, headers: admin.create_new_auth_token, params: params.merge(force: true), as: :json
    expect(response).to have_http_status(:ok)
    expect(Lla::Knowledge::GenerationOperation.sole.items.sole.item_type).to eq('translation')
  end

  it 'rejects changed content under the same idempotency key' do
    account.enable_features!('captain_tasks')
    headers = admin.create_new_auth_token.merge('Idempotency-Key' => 'translation:request-123')
    post url, headers: headers, params: params, as: :json

    post url, headers: headers, params: params.merge(force: true), as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq('lla_knowledge_idempotency_conflict')
    expect(Lla::Knowledge::GenerationOperation.count).to eq(1)
  end

  it 'persists nothing when provider consent is absent' do
    account.enable_features!('captain_tasks')
    account.update!(custom_attributes: account.custom_attributes.except('lla_provider_consents'))

    expect do
      expect do
        post url, headers: admin.create_new_auth_token, params: params, as: :json
      end.not_to have_enqueued_job(Lla::Knowledge::GenerationOutboxDispatchJob)
    end.not_to change(Lla::Knowledge::GenerationOperation, :count)

    expect(response).to have_http_status(:unprocessable_entity)
  end
end
