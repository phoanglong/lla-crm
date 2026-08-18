# frozen_string_literal: true

require 'rails_helper'

# The knowledge-base privilege boundary, asserted at the request boundary rather than
# at the policy object.
#
# Wave G4b's policy specs hand Pundit a record *instance*, but every knowledge-base
# controller authorizes through `Api::BaseController#check_authorization`, which does
# `authorize(controller_name.classify.constantize)` — Pundit's record is the *class*.
# `Article.respond_to?(:account_id)` is false, so `Lla::ArticlePolicy#record_within_account?`
# short-circuits to true on every real request and the cross-tenant assertion those
# specs make is never the code path a request takes. What actually holds the boundary
# is the controller's account scoping, and that is what this file pins.
#
# It also restores the two assertions that were lost when Wave G4b deleted
# `spec/lla/requests/portal_privilege_spec.rb` on its way to giving the portal
# controller back to G4a: that a `knowledge_base_manage` custom role really can edit
# knowledge-base content through the API, and that it really cannot touch the
# custom-domain lifecycle. Note the status contract is G4a's — 403 with
# `lla_custom_domain_forbidden`, not G4b's 401.
RSpec.describe 'Knowledge base privilege boundary', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:portal) { create(:portal, account: account, slug: 'own-portal') }
  let(:foreign_portal) { create(:portal, account: other_account, slug: 'foreign-portal') }
  let(:administrator) { create(:user, account: account, role: :administrator) }

  describe 'a member of one account reaching for another account' do
    it 'cannot read a portal that belongs to a different tenant' do
      foreign_portal

      get "/api/v1/accounts/#{account.id}/portals/#{foreign_portal.slug}",
          headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'cannot write a portal that belongs to a different tenant' do
      foreign_portal
      original = foreign_portal.name

      patch "/api/v1/accounts/#{account.id}/portals/#{foreign_portal.slug}",
            params: { portal: { name: 'taken over' } },
            headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(foreign_portal.reload.name).to eq(original)
    end

    it 'cannot read an article that belongs to a different tenant' do
      foreign_article = create(:article, account: other_account, portal: foreign_portal,
                                         author: create(:user, account: other_account, role: :administrator))

      get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/articles/#{foreign_article.id}",
          headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(foreign_article.reload.account_id).to eq(other_account.id)
    end
  end

  describe 'a custom role that may manage knowledge-base content' do
    before { skip('custom roles are unavailable in this build') unless ChatwootApp.custom_roles? }

    let(:custom_role) { create(:custom_role, account: account, permissions: ['knowledge_base_manage']) }
    let(:content_editor) do
      user = create(:user, account: account, role: :agent)
      account.account_users.find_by!(user_id: user.id).update!(custom_role: custom_role)
      user
    end

    it 'may edit an article through the API' do
      article = create(:article, account: account, portal: portal, author: administrator, title: 'before')

      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/articles/#{article.id}",
            params: { article: { title: 'after' } },
            headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(article.reload.title).to eq('after')
    end

    it 'may not move the custom domain, and is told so with the lifecycle error code' do
      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { custom_domain: 'docs.example.com' } },
            headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error_code']).to eq('lla_custom_domain_forbidden')
      expect(portal.reload.custom_domain).to be_blank
    end

    # Denied by `PortalPolicy#custom_domain_reverify?` before G4a's controller guard
    # is reached, so this one answers 401 rather than the 403 the field-level guard
    # renders. Two layers, one outcome; the assertion is that it is refused.
    it 'may not trigger a custom-domain reverification' do
      post "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/custom_domain_reverify",
           headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
