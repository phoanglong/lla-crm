# frozen_string_literal: true

require 'rails_helper'

# A deployment file that names a switch nothing reads is worse than one that omits
# it: it reads as a decision that has been made and enforced. Two of them shipped in
# the UAT stack — `LLA_EGRESS_ENABLED` and `LLA_CUSTOM_DOMAIN_ENABLED`, neither of
# which appears anywhere in the application. The posture happened to be correct,
# because an unset flag is off, but nothing about the file made that true.
#
# This keeps the deployment files and the code honest in both directions.
RSpec.describe 'UAT capability flags' do # rubocop:disable RSpec/DescribeClass
  let(:env_example) { Rails.root.join('deployment/uat/.env.uat.example') }
  let(:compose) { Rails.root.join('deployment/uat/compose.lla-uat.yaml') }

  # Secret *references*, not secrets: these are looked up just in time and are
  # allowed to be named without being boolean capability switches.
  let(:reference_flags) { %w[LLA_CLOUDFLARE_API_TOKEN_REF LLA_CLOUDFLARE_ZONE_ID_REF LLA_CONTEXT_DEV_API_KEY_REF] }

  # Flags the application genuinely reads, wherever it reads them.
  let(:readable_flags) do
    policy = Lla::Knowledge::ProviderPolicy
    (policy::CAPABILITY_FLAGS.values + [policy::GLOBAL_EGRESS_FLAG] +
      %w[DISABLE_ENTERPRISE LLA_WIDGET_GEOIP_ENABLED]).sort.uniq
  end

  def declared_in(path)
    path.read.scan(/^\s*([A-Z][A-Z0-9_]*)\s*[:=]/).flatten.uniq
  end

  it 'names only flags the application actually reads' do
    declared = (declared_in(env_example) + declared_in(compose)).uniq
    capability_like = declared.grep(/\A(LLA_|DISABLE_ENTERPRISE)/) - reference_flags

    unknown = capability_like.reject do |flag|
      readable_flags.include?(flag) || flag.start_with?('LLA_IMAGE', 'LLA_UAT_', 'LLA_CACHE_')
    end

    expect(unknown).to be_empty,
                       "the UAT deployment files set #{unknown.join(', ')}, which nothing in the application reads"
  end

  it 'declares every provider capability the policy knows about, so none is left to a default' do
    declared = declared_in(env_example)
    missing = (Lla::Knowledge::ProviderPolicy::CAPABILITY_FLAGS.values +
               [Lla::Knowledge::ProviderPolicy::GLOBAL_EGRESS_FLAG]).uniq - declared

    expect(missing).to be_empty,
                       "deployment/uat/.env.uat.example does not state a value for #{missing.join(', ')}"
  end

  it 'holds every capability off' do
    values = env_example.read.scan(/^(LLA_[A-Z0-9_]*ENABLED)=(.*)$/)

    expect(values).not_to be_empty
    values.each do |flag, value|
      expect(ChatwootApp.enabled_flag?(flag)).to be(false), "#{flag} would be read as enabled"
      expect(value.strip).to eq('false'), "#{flag} is set to #{value.inspect}, not false"
    end
  end
end
