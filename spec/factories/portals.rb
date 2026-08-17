FactoryBot.define do
  factory :portal, class: 'Portal' do
    account
    name { Faker::Book.name }
    slug { SecureRandom.hex }

    # A portal built with a custom domain represents an already established
    # domain, so it resolves for public/dashboard host lookup. The lifecycle that
    # gets a domain to `active` (canonicalisation, ownership proof, provisioning,
    # teardown) is exercised in spec/lla/services/lla/custom_domains.
    after(:create) do |portal|
      domain = portal.lla_custom_domain
      domain&.update!(state: 'active', ownership_verified_at: Time.current, activated_at: Time.current)
    end
  end
end
