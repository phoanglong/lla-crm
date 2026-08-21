# frozen_string_literal: true

require 'rails_helper'

# The route-gating cluster: six premium capabilities were reachable only by typing
# their URL. Each sidebar entry was gated on the *edition*
# (`installationTypes: [CLOUD, ENTERPRISE]`) instead of on the capability, and on LLA
# — neither Cloud nor the deleted `enterprise/` — that check was always false, so the
# navigation entry never appeared even though the routes and the server behind them
# existed. Same shape as the changelog card, the testimonials column and the Calls
# entry: the question is always "is the capability present", not "which edition".
#
# LLA entitles these, so they ship enabled by default. This guards both halves: the
# features stay entitled (a `features.yml` revert is caught), and a fresh account
# actually receives them.
RSpec.describe 'the capabilities LLA entitles' do # rubocop:disable RSpec/DescribeClass
  # Captain is deliberately excluded: it is being reshaped into a bring-your-own-AI
  # hub (LLA.Mochi) that connects to the operator's own Claude/ChatGPT, and stays
  # gated until a provider can be connected — surfacing it now would lead to a screen
  # with nothing behind it.
  let(:entitled) { %w[companies custom_roles audit_logs sla saml] }

  it 'declares them enabled by default in features.yml' do
    features = YAML.safe_load(Rails.root.join('config/features.yml').read)
                   .index_by { |feature| feature['name'] }

    entitled.each do |name|
      expect(features.dig(name, 'enabled')).to be(true), "#{name} must stay entitled for LLA"
    end
  end

  it 'gives a newly created account access to each of them' do
    ConfigLoader.new.process(reconcile_only_new: false)
    account = create(:account)

    entitled.each do |name|
      expect(account.feature_enabled?(name)).to be(true), "a new account cannot reach #{name}"
    end
  end
end
