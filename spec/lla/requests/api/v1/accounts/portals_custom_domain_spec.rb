# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Portal custom-domain lifecycle', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:portal) { create(:portal, account: account) }
  # A custom role holding the *content* permission the enterprise portal policy
  # accepts for `update?`. It must not be able to move DNS.
  let(:content_editor) do
    user = create(:user, account: account, role: :agent)
    role = create(:custom_role, account: account, permissions: ['knowledge_base_manage'])
    AccountUser.find_by!(account: account, user: user).update!(custom_role: role)
    user
  end

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'POST /api/v1/accounts/:account_id/portals' do
    it 'stores the canonical hostname and starts the ownership lifecycle' do
      post "/api/v1/accounts/#{account.id}/portals",
           params: { portal: { name: 'Docs', slug: SecureRandom.hex, custom_domain: 'Docs.Example.com.' } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      created = Portal.find_by(custom_domain: 'docs.example.com')
      expect(created).to be_present
      expect(created.lla_custom_domain).to have_attributes(state: 'ownership_pending', account_id: account.id)
    end

    it 'rejects a malformed hostname with a stable error instead of a 500' do
      post "/api/v1/accounts/#{account.id}/portals",
           params: { portal: { name: 'Docs', slug: SecureRandom.hex, custom_domain: "docs.example.com\r\nX: 1" } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('lla_custom_domain_control_character')
      expect(Lla::CustomDomains::Domain.count).to eq(0)
    end

    it 'refuses a hostname already claimed by another account' do
      other_portal = create(:portal, account: create(:account))
      Lla::CustomDomains::LifecycleService.new(portal: other_portal).request!('docs.example.com')

      post "/api/v1/accounts/#{account.id}/portals",
           params: { portal: { name: 'Docs', slug: SecureRandom.hex, custom_domain: 'docs.example.com' } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Lla::CustomDomains::Domain.where(hostname: 'docs.example.com').pluck(:portal_id)).to eq([other_portal.id])
    end
  end

  describe 'PATCH /api/v1/accounts/:account_id/portals/:id' do
    it 'canonicalises and repoints on update as well as on create' do
      portal.update!(custom_domain: 'docs.example.com')

      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { custom_domain: 'HELP.Example.com' } },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(portal.reload.custom_domain).to eq('help.example.com')
      expect(portal.lla_custom_domain).to have_attributes(hostname: 'help.example.com', version: 2)
    end

    it 'schedules a teardown when the domain is cleared' do
      portal.update!(custom_domain: 'docs.example.com')

      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { custom_domain: '' } },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(portal.reload.custom_domain).to be_nil
      expect(Lla::CustomDomains::Domain.find_by(portal_id: portal.id).state).to eq('removing')
    end
  end

  describe 'GET ssl_status' do
    it 'reports the LLA lifecycle without any provider call or token' do
      portal.update!(custom_domain: 'docs.example.com')

      get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/ssl_status",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(custom_domain: 'docs.example.com', lifecycle_state: 'ownership_pending',
                                       provider: 'none')
      expect(response.body).not_to include(portal.lla_custom_domain.challenge_ciphertext.to_s)
      expect(WebMock).not_to have_requested(:any, //)
    end

    it 'reports readiness without a configured domain and without leaking state' do
      get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/ssl_status",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(configured: false, lifecycle_state: nil,
                                       capability_enabled: false, provider_ready: false, can_manage: true)
      expect(WebMock).not_to have_requested(:any, //)
    end

    it 'tells a non-administrator that it cannot manage the domain' do
      portal.update!(custom_domain: 'docs.example.com')

      get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/ssl_status",
          headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(can_manage: false, lifecycle_state: 'ownership_pending')
    end

    it 'does not expose another account portal' do
      foreign = create(:portal, account: create(:account), custom_domain: 'docs.example.com')

      get "/api/v1/accounts/#{account.id}/portals/#{foreign.slug}/ssl_status",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('docs.example.com')
    end

    it 'refuses an unauthenticated caller' do
      portal.update!(custom_domain: 'docs.example.com')

      get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/ssl_status", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include('docs.example.com')
    end
  end

  # The escalation these examples close is created by the *enterprise* portal policy,
  # which accepts `knowledge_base_manage` for `update?`. With enterprise disabled the
  # custom role does not exist at all, so the scenario is not reachable there.
  describe 'field-level authorization' do
    before { skip('custom roles are unavailable in this build') unless ChatwootApp.custom_roles? }

    it 'refuses a custom-domain change from a content role that may edit the portal' do
      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { custom_domain: 'docs.example.com' } },
            headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(json_response[:error_code]).to eq('lla_custom_domain_forbidden')
      expect(portal.reload.custom_domain).to be_nil
      expect(Lla::CustomDomains::Domain.count).to eq(0)
    end

    it 'still lets that content role edit portal content' do
      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { page_title: 'Docs' } },
            headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(portal.reload.page_title).to eq('Docs')
    end

    it 'refuses a content role trying to clear an existing domain' do
      portal.update!(custom_domain: 'docs.example.com')

      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { custom_domain: '' } },
            headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(portal.reload.custom_domain).to eq('docs.example.com')
    end

    it 'lets a content role re-submit the unchanged domain without escalating' do
      portal.update!(custom_domain: 'docs.example.com')

      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { custom_domain: 'DOCS.example.com', page_title: 'Docs' } },
            headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(portal.reload).to have_attributes(custom_domain: 'docs.example.com', page_title: 'Docs')
    end

    it 'refuses a malformed domain from a content role before the model sees it' do
      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { custom_domain: "docs.example.com\r\nX: 1" } },
            headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses a reverify request from a content role' do
      portal.update!(custom_domain: 'docs.example.com')

      post "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/custom_domain_reverify",
           headers: content_editor.create_new_auth_token, as: :json

      # Denied by the policy before the field guard even runs: defence in depth.
      expect(response).to have_http_status(:unauthorized)
      expect(Lla::CustomDomains::Operation.where(operation_type: 'reverify')).to be_empty
    end

    it 'refuses a cross-tenant reverify' do
      foreign = create(:portal, account: create(:account), custom_domain: 'docs.example.com')

      post "/api/v1/accounts/#{account.id}/portals/#{foreign.slug}/custom_domain_reverify",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'legacy reverification' do
    let(:domain) { portal.reload.lla_custom_domain }

    before do
      portal.update!(custom_domain: 'docs.example.com')
      portal.lla_custom_domain.update!(state: 'active', ownership_source: 'legacy_import',
                                       reverify_required: true, ownership_verified_at: nil, activated_at: nil)
    end

    it 'lets an administrator start a bounded reverification with zero egress' do
      post "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/custom_domain_reverify",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(reverify_required: true, ownership_source: 'legacy_import',
                                       lifecycle_state: 'active')
      expect(Lla::CustomDomains::Operation.where(operation_type: 'reverify').count).to eq(1)
      expect(domain.reload.challenge_active?).to be(true)
      expect(WebMock).not_to have_requested(:any, //)
    end

    it 'is idempotent when pressed twice' do
      2.times do
        post "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/custom_domain_reverify",
             headers: admin.create_new_auth_token, as: :json
      end

      expect(Lla::CustomDomains::Operation.where(operation_type: 'reverify').count).to eq(1)
    end

    it 'refuses when the domain is already proved' do
      domain.update!(ownership_source: 'nonce_challenge', reverify_required: false,
                     ownership_verified_at: Time.current, activated_at: Time.current)

      post "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/custom_domain_reverify",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response[:error_code]).to eq('lla_custom_domain_reverify_not_applicable')
    end
  end

  describe 'a rejected domain change leaves no trace' do
    # The rescue used to sit inside the transaction block, so a hostname the
    # lifecycle refused was rendered as a 422 *and* committed to portals.custom_domain
    # — permanently squatting the globally unique hostname for another tenant.
    it 'rolls the portal back when the hostname belongs to another tenant' do
      other_portal = create(:portal, account: create(:account))
      Lla::CustomDomains::LifecycleService.new(portal: other_portal).request!('docs.example.com')
      portal.update!(custom_domain: 'own.example.com')

      patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
            params: { portal: { custom_domain: 'docs.example.com' } },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(portal.reload.custom_domain).to eq('own.example.com')
      expect(Lla::CustomDomains::Domain.where(hostname: 'docs.example.com').pluck(:portal_id))
        .to eq([other_portal.id])
    end
  end

  describe 'POST /api/v1/accounts/:account_id/portals/:id/custom_domain_reverify on a failed domain' do
    it 'starts a new attempt instead of leaving the administrator with a dead end' do
      portal.update!(custom_domain: 'docs.example.com')
      domain = portal.reload.lla_custom_domain
      Lla::CustomDomains::LifecycleService.new(portal: portal)
                                          .fail!(domain, code: 'lla_custom_domain_ownership_unverified')

      post "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/custom_domain_reverify",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(lifecycle_state: 'ownership_pending', retry_available: false)
      expect(domain.reload).to have_attributes(state: 'ownership_pending', last_error_code: nil)
      expect(WebMock).not_to have_requested(:any, //)
    end
  end

  describe 'portal JSON entitlement' do
    # The dashboard derives "can I manage this domain?" from the portal payload, so
    # an administrator opening a portal that has no custom domain yet must still be
    # told they may add one.
    it 'always reports capability, provider readiness and permission' do
      get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:ssl_settings]).to include(can_manage: true, configured: false,
                                                      capability_enabled: false, provider_ready: false)
    end

    it 'reports a content role as unable to manage the domain' do
      skip('custom roles are unavailable in this build') unless ChatwootApp.custom_roles?

      get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
          headers: content_editor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:ssl_settings]).to include(can_manage: false)
    end
  end

  describe 'public host lookup' do
    it 'refuses an unregistered host with LLA copy and without reflecting the Host' do
      portal.update!(custom_domain: 'docs.example.com')
      host! 'evil.example.com'
      get "/hc/#{portal.slug}"

      expect(response).to have_http_status(:unauthorized)
      expect(json_response[:error_code]).to eq('lla_custom_domain_not_registered')
      expect(response.body).not_to include('evil.example.com')
      expect(response.body).not_to include('chatwoot')
    end
  end
end
