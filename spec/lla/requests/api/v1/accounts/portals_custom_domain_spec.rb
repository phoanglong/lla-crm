# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Portal custom-domain lifecycle', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:portal) { create(:portal, account: account) }

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

    it 'reports a missing configuration instead of leaking state' do
      get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}/ssl_status",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
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
