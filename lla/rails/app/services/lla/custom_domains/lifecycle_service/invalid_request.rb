# frozen_string_literal: true

# The lifecycle refused a request. `code` is the stable identifier the API and the
# UI show; the message is never a raw provider or database string.
class Lla::CustomDomains::LifecycleService::InvalidRequest < StandardError
  attr_reader :code

  def initialize(code = 'lla_custom_domain_invalid_request')
    @code = code
    super(code)
  end
end
