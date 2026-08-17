# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla do
  let(:source_locations) do
    {
      portal_concern: Portal.instance_method(:custom_domain_state).source_location.first,
      portal_ssl_status: Api::V1::Accounts::PortalsController.instance_method(:ssl_status).source_location.first,
      challenge_controller: CustomDomainsController.instance_method(:verify).source_location.first,
      challenge_resolver: Lla::CustomDomains::ChallengeResolver.method(:resolve).source_location.first,
      host_resolver: Lla::CustomDomains::HostResolver.method(:portal_for).source_location.first,
      lifecycle: Lla::CustomDomains::LifecycleService.instance_method(:request!).source_location.first,
      cloudflare_provider: Lla::CustomDomains::Providers::CloudflareProvider.method(:provision).source_location.first,
      website_branding: WebsiteBrandingService.instance_method(:perform).source_location.first,
      secret_reference: Lla::Security::SecretReference.method(:resolve).source_location.first
    }
  end

  it 'owns every G4a runtime entry point in the LLA load path' do
    expect(source_locations.values).to all(include('/lla/rails/'))
  end

  it 'includes the LLA portal extension exactly once' do
    expect(Portal.ancestors.count { |ancestor| ancestor == Lla::Concerns::Portal }).to eq(1)
  end

  it 'prepends the LLA branding extension exactly once' do
    expect(WebsiteBrandingService.ancestors.count { |ancestor| ancestor == Lla::WebsiteBrandingService }).to eq(1)
  end

  it 'removes the superseded Enterprise custom-domain and branding runtime files' do
    legacy_paths = %w[
      enterprise/app/controllers/enterprise/api/v1/accounts/portals_controller.rb
      enterprise/app/jobs/enterprise/cloudflare_verification_job.rb
      enterprise/app/models/enterprise/concerns/portal.rb
      enterprise/app/services/cloudflare/base_cloudflare_zone_service.rb
      enterprise/app/services/cloudflare/check_custom_hostname_service.rb
      enterprise/app/services/cloudflare/create_custom_hostname_service.rb
      enterprise/app/services/enterprise/website_branding_service.rb
    ]

    expect(legacy_paths.select { |path| Rails.root.join(path).exist? }).to be_empty
  end

  it 'keeps the custom-domain routes reachable and the capability off by default' do
    expect(Rails.application.routes.recognize_path('/.well-known/cf-custom-hostname-challenge/abc'))
      .to include(controller: 'custom_domains', action: 'verify')
    expect(Lla::Knowledge::ProviderPolicy.capability_enabled?(:custom_domains)).to be(false)
    expect(Lla::CustomDomains::ProviderRegistry.default_provider).to eq('none')
  end

  it 'reads no plaintext provider credential from InstallationConfig' do
    sources = Dir[Rails.root.join('lla/rails/app/services/lla/custom_domains/**/*.rb')].map { |path| File.read(path) }

    expect(sources.join).not_to match(/InstallationConfig/)
  end
end
