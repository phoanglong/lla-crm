# frozen_string_literal: true

# Typed adapter errors. The distinction that matters operationally is
# "the provider is sure the hostname does not exist" (NotFound) versus
# "we do not know" (Timeout / ServerError / ClientError): only the first one may
# ever lead to a create, otherwise an outage silently duplicates hostnames.
module Lla::CustomDomains::ProviderErrors
  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  # The provider is not configured or the capability is off: fail closed.
  class NotConfigured < Error
    def initialize(code = 'lla_custom_domain_provider_not_configured')
      super
    end
  end

  # Authoritative negative answer.
  class NotFound < Error
    def initialize(code = 'lla_custom_domain_provider_not_found')
      super
    end
  end

  class Unauthorized < Error
    def initialize(code = 'lla_custom_domain_provider_unauthorized')
      super
    end
  end

  class ClientError < Error
    def initialize(code = 'lla_custom_domain_provider_client_error')
      super
    end
  end

  class ServerError < Error
    def initialize(code = 'lla_custom_domain_provider_server_error')
      super
    end
  end

  class Timeout < Error
    def initialize(code = 'lla_custom_domain_provider_timeout')
      super
    end
  end

  # Errors after which the caller still does not know remote state.
  INDETERMINATE = [Timeout, ServerError, ClientError, Unauthorized, NotConfigured].freeze

  def self.indeterminate?(error)
    INDETERMINATE.any? { |klass| error.is_a?(klass) }
  end
end
