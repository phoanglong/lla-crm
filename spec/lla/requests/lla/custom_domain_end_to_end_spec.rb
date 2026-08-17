# frozen_string_literal: true

require 'rails_helper'

# The whole administrator journey in one place, driven only through HTTP and the
# fake (local) provider adapter: add a domain, publish the proof, let the queue run
# it, watch it go live, change it, remove it. Every step asserts the exact
# `ssl_settings` payload the dashboard renders from, so a change that would make the
# UI claim success too early fails here rather than in production.
#
# No real provider, no DNS and no network: the proof is fetched through a stubbed
# boundary and WebMock asserts that nothing left the process.
RSpec.describe 'LLA custom domain end to end', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:portal) { create(:portal, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def ssl_settings
    get "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
        headers: admin.create_new_auth_token, as: :json
    json_response[:ssl_settings]
  end

  def set_domain!(value, user: admin)
    patch "/api/v1/accounts/#{account.id}/portals/#{portal.slug}",
          params: { portal: { custom_domain: value } },
          headers: user.create_new_auth_token, as: :json
  end

  # Runs whatever the queue currently has to do, the way the dispatch job would.
  # Time is advanced between passes so a retry backoff does not silently stall the
  # drain — the point of the walk is that the lifecycle *does* converge on its own.
  def drain_operations!
    10.times do
      operation = Lla::CustomDomains::Operation.dispatchable.order(:id).first
      if operation.blank?
        travel 5.minutes
        operation = Lla::CustomDomains::Operation.dispatchable.order(:id).first
      end
      break if operation.blank?

      Lla::CustomDomains::OperationDispatchJob.perform_now(operation.id)
    end
  end

  # The customer publishing the CNAME/proof: the verifier reads it through this
  # boundary, which is stubbed rather than reached over the network.
  def publish_proof!(domain)
    allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify) do |candidate|
      Lla::CustomDomains::OwnershipChallenge.probe_path(candidate).present? ? :verified : :unverified
    end
    domain
  end

  # Deliberately one long example: the value of this test is the *sequence*, and
  # splitting it into per-step examples would lose the ordering it exists to pin.
  it 'walks add, prove, provision, live, change and remove without ever claiming success early' do # rubocop:disable RSpec/MultipleExpectations
    expect(ssl_settings).to include(configured: false, can_manage: true, lifecycle_state: nil,
                                    reverify_available: false, retry_available: false)

    set_domain!('Docs.Example.com.')
    expect(response).to have_http_status(:success)

    domain = portal.reload.lla_custom_domain
    expect(domain).to have_attributes(hostname: 'docs.example.com', state: 'ownership_pending')
    expect(ssl_settings).to include(configured: true, lifecycle_state: 'ownership_pending',
                                    custom_domain: 'docs.example.com')

    # Before the proof is readable the queue must not move the domain on.
    allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:unverified)
    Lla::CustomDomains::OperationDispatchJob.perform_now(
      Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id, operation_type: 'verify').id
    )
    expect(domain.reload.state).to eq('ownership_pending')
    expect(Lla::CustomDomains::HostResolver.portal_for('docs.example.com')).to be_nil

    publish_proof!(domain)
    drain_operations!

    expect(domain.reload).to have_attributes(state: 'active', ownership_source: 'nonce_challenge',
                                             reverify_required: false, provider: 'none')
    expect(domain.ownership_verified_at).to be_present
    expect(Lla::CustomDomains::HostResolver.portal_for('docs.example.com')).to eq(portal)
    expect(ssl_settings).to include(lifecycle_state: 'active', status: 'local', reverify_available: false,
                                    retry_available: false, verification_errors: '')

    # Changing the hostname starts a brand new proof and stops serving the old one.
    set_domain!('help.example.com')
    expect(response).to have_http_status(:success)
    expect(domain.reload).to have_attributes(hostname: 'help.example.com', state: 'ownership_pending')
    expect(Lla::CustomDomains::HostResolver.portal_for('docs.example.com')).to be_nil

    drain_operations!
    expect(domain.reload.state).to eq('active')

    # Clearing it removes the row entirely; nothing keeps serving.
    set_domain!('')
    expect(response).to have_http_status(:success)
    drain_operations!

    expect(Lla::CustomDomains::Domain.where(portal_id: portal.id)).not_to exist
    expect(Lla::CustomDomains::HostResolver.portal_for('help.example.com')).to be_nil
    expect(ssl_settings).to include(configured: false, lifecycle_state: nil)
    expect(WebMock).not_to have_requested(:any, //)
  end

  it 'refuses the whole journey to a caller who may not manage the domain' do
    set_domain!('docs.example.com', user: agent)

    expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
    expect(Lla::CustomDomains::Domain.count).to eq(0)
    expect(portal.reload.custom_domain).to be_nil
  end

  it 'renders a manual-intervention teardown honestly instead of reporting removal' do
    set_domain!('docs.example.com')
    domain = portal.reload.lla_custom_domain
    publish_proof!(domain)
    drain_operations!
    set_domain!('')
    domain.reload.update!(last_error_code: Lla::CustomDomains::ReconciliationJob::MANUAL_INTERVENTION_CODE)

    expect(ssl_settings).to include(lifecycle_state: 'removing', manual_intervention_required: true)
    expect(Lla::CustomDomains::HostResolver.portal_for('docs.example.com')).to be_nil
    expect(WebMock).not_to have_requested(:any, //)
  end

  it 'keeps the provider disabled by default and says so instead of pretending it is ready' do
    set_domain!('docs.example.com')

    expect(ssl_settings).to include(provider_ready: false, capability_enabled: false)
    expect(portal.reload.lla_custom_domain.provider).to eq('none')
    expect(WebMock).not_to have_requested(:any, //)
  end
end
