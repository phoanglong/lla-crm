# frozen_string_literal: true

# Which capabilities this installation is entitled to, decided locally.
#
# The inherited answer came from `ChatwootHub.pricing_plan`, which reads an
# `InstallationConfig` row that only Chatwoot's hosted hub writes. Six product
# capabilities — custom branding, agent capacity, audit logs, branding removal,
# voice calls and more — were gated on that value being something other than
# `community`. On an installation that never talks to the hub, the value is always
# `community`, so those capabilities were permanently off and no operator action
# could turn them on. A remote party deciding what a self-hosted installation may
# run is exactly what Wave J removes.
#
# The plan is now an installation-local setting with a documented default, and no
# code path outside this module may change it.
module Lla::Entitlements
  PLAN_CONFIG_KEY = 'LLA_INSTALLATION_PLAN'
  SEATS_CONFIG_KEY = 'LLA_INSTALLATION_SEATS'
  DEFAULT_PLAN = 'lla'
  KNOWN_PLANS = %w[community lla].freeze

  module_function

  # `lla` by default: a deployment of this product is a deployment of this product.
  # An operator can set the row to `community` to run without the LLA capabilities;
  # anything else is not a plan and reads as the default rather than as an unknown
  # state that silently disables things.
  def plan
    value = installation_value(PLAN_CONFIG_KEY).to_s.strip.downcase
    KNOWN_PLANS.include?(value) ? value : DEFAULT_PLAN
  end

  def seat_count
    installation_value(SEATS_CONFIG_KEY).to_i
  end

  # The question every feature gate actually asks.
  def premium?
    plan != 'community'
  end

  def installation_value(key)
    InstallationConfig.find_by(name: key)&.value
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
    # Read during boot or before migrations, where a missing table must not take
    # the process with it.
    nil
  end
end
