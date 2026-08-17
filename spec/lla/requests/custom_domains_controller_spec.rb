require 'rails_helper'

RSpec.describe 'LLA custom-domain challenge', type: :request do
  let!(:portal) do
    create(
      :portal,
      custom_domain: 'docs.example.com',
      ssl_settings: {
        'cf_verification_id' => 'challenge-123',
        'cf_verification_body' => 'proof-body',
        'cf_verification_expires_at' => 10.minutes.from_now.iso8601
      }
    )
  end

  before { host! portal.custom_domain }

  it 'fails closed while the LLA capability is disabled' do
    get '/.well-known/cf-custom-hostname-challenge/challenge-123'

    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include('proof-body')
  end

  it 'serves an exact non-expired challenge when explicitly enabled' do
    with_modified_env('LLA_CUSTOM_DOMAINS_ENABLED' => 'true') do
      get '/.well-known/cf-custom-hostname-challenge/challenge-123'
    end

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('proof-body')
  end
end
