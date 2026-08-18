# frozen_string_literal: true

# The hostname is already registered to some other portal or tenant. A subclass so
# that a caller can rescue either the whole refusal contract or just this case.
class Lla::CustomDomains::LifecycleService::Conflict < Lla::CustomDomains::LifecycleService::InvalidRequest
  def initialize(code = 'lla_custom_domain_taken')
    super
  end
end
