# frozen_string_literal: true

require 'rails_helper'

# Wave G4b relocated knowledge-base authorization and widget GeoIP enforcement from
# the Enterprise overlay into lla/rails. These assertions pin the runtime ownership
# and prove the superseded Enterprise files are gone, in both EE ON and EE OFF modes.
RSpec.describe Lla do
  it 'resolves the overridden policy and widget geo entry points to the LLA load path' do
    source_locations = {
      article_update: ArticlePolicy.instance_method(:update?).source_location.first,
      category_update: CategoryPolicy.instance_method(:update?).source_location.first,
      portal_update: PortalPolicy.instance_method(:update?).source_location.first,
      widget_geo: WidgetsController.instance_method(:ensure_location_is_supported).source_location.first,
      gatekeeper: Lla::Widget::GeoGatekeeper.instance_method(:call).source_location.first,
      trusted_ip: Lla::Widget::TrustedClientIp.instance_method(:resolve).source_location.first,
      single_flight: Lla::Widget::SingleFlight.instance_method(:call).source_location.first
    }

    expect(source_locations.values).to all(include('/lla/rails/'))
  end

  it 'removes the superseded Enterprise runtime files' do
    # The whole G4 union, not just G4b's four: a bad merge that resurrects any file
    # either branch removed has to fail here rather than in production.
    legacy_paths = %w[
      enterprise/app/controllers/enterprise/api/v1/accounts/portals_controller.rb
      enterprise/app/controllers/enterprise/widgets_controller.rb
      enterprise/app/jobs/enterprise/cloudflare_verification_job.rb
      enterprise/app/models/enterprise/concerns/portal.rb
      enterprise/app/policies/enterprise/article_policy.rb
      enterprise/app/policies/enterprise/category_policy.rb
      enterprise/app/policies/enterprise/portal_policy.rb
      enterprise/app/services/cloudflare/base_cloudflare_zone_service.rb
      enterprise/app/services/cloudflare/check_custom_hostname_service.rb
      enterprise/app/services/cloudflare/create_custom_hostname_service.rb
      enterprise/app/services/enterprise/website_branding_service.rb
    ]

    expect(legacy_paths.select { |path| Rails.root.join(path).exist? }).to be_empty
  end
end
