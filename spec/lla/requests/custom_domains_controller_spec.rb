# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'LLA custom-domain challenge', type: :request do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:domain) { Lla::CustomDomains::LifecycleService.new(portal: portal).request!('docs.example.com') }
  let(:challenge) { Lla::CustomDomains::OwnershipChallenge.issue!(domain) }

  def get_challenge(id, host: 'docs.example.com')
    host!(host)
    get "/.well-known/cf-custom-hostname-challenge/#{id}"
  end

  it 'fails closed while the LLA capability is disabled' do
    get_challenge(challenge.id)

    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(challenge.body)
  end

  context 'when the capability is explicitly enabled' do
    around { |example| with_modified_env('LLA_CUSTOM_DOMAINS_ENABLED' => 'true') { example.run } }

    it 'serves the exact live challenge' do
      get_challenge(challenge.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(challenge.body)
    end

    it 'returns an indistinguishable 404 for a wrong, expired or revoked challenge' do
      get_challenge("#{challenge.id}x")
      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_blank

      Lla::CustomDomains::OwnershipChallenge.revoke!(domain)
      get_challenge(challenge.id)
      expect(response).to have_http_status(:not_found)
    end

    it 'does not serve one tenant challenge on another tenant host' do
      other = Lla::CustomDomains::LifecycleService.new(portal: create(:portal, account: create(:account)))
                                                  .request!('help.example.com')
      Lla::CustomDomains::OwnershipChallenge.issue!(other)

      get_challenge(challenge.id, host: 'help.example.com')

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(challenge.body)
    end

    it 'does not serve a challenge for a domain that already left ownership_pending' do
      domain.update!(state: 'provisioning', ownership_verified_at: Time.current)

      get_challenge(challenge.id)

      expect(response).to have_http_status(:not_found)
    end
  end
end
