# frozen_string_literal: true

require 'rails_helper'

# Proves the content/custom-domain separation at the request boundary: a
# knowledge_base_manage content role may edit portal content and articles but cannot
# change the portal custom_domain (a DNS/domain-lifecycle field). Renders JSON only, so
# it runs identically under EE ON and DISABLE_ENTERPRISE=true.
RSpec.describe 'LLA portal privilege separation', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:custom_role) { create(:custom_role, account: account, permissions: ['knowledge_base_manage']) }
  let(:content_agent) { create(:user) }
  let(:content_account_user) do
    create(:account_user, user: content_agent, account: account, role: :agent, custom_role: custom_role)
  end
  let!(:portal) { create(:portal, account: account, slug: 'kb-portal', name: 'original') }
  let!(:category) { create(:category, account: account, portal: portal, slug: 'guides', locale: 'en') }
  let!(:article) { create(:article, account: account, portal: portal, category: category, author: admin) }

  before { content_account_user }

  def put_portal(params, user)
    put "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
        params: params, headers: user.create_new_auth_token, as: :json
  end

  context 'when the actor is a knowledge_base_manage content role' do
    it 'permits editing portal content fields' do
      put_portal({ portal: { name: 'edited-by-content-role' } }, content_agent)
      expect(response).to have_http_status(:success)
      expect(portal.reload.name).to eq('edited-by-content-role')
    end

    it 'permits editing an article' do
      put "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/articles/#{article.id}",
          params: { article: { title: 'edited-title' } }, headers: content_agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:success)
    end

    it 'rejects changing the portal custom_domain' do
      put_portal({ portal: { custom_domain: 'content-role.example.com' } }, content_agent)
      expect(response).to have_http_status(:unauthorized)
      expect(portal.reload.custom_domain).to be_blank
    end
  end

  context 'when the actor is an administrator' do
    it 'permits changing the portal custom_domain' do
      put_portal({ portal: { custom_domain: 'docs.example.com' } }, admin)
      expect(response).to have_http_status(:success)
      expect(portal.reload.custom_domain).to eq('docs.example.com')
    end
  end
end
