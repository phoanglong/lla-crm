# frozen_string_literal: true

class Lla::Captain::QuotaPolicy
  CUSTOMER_RESPONSE = :customer_response
  INTERNAL = :internal
  SYSTEM = :system
  ACCOUNT_HOOK = :account_hook

  MATRIX = {
    CUSTOMER_RESPONSE => { SYSTEM => true, ACCOUNT_HOOK => false }.freeze,
    INTERNAL => { SYSTEM => false, ACCOUNT_HOOK => false }.freeze
  }.freeze

  class << self
    def billable?(workload:, credential_source:)
      workload = workload.to_sym
      source = normalize_source(credential_source)
      return true unless MATRIX.key?(workload)

      MATRIX.fetch(workload).fetch(source, workload == CUSTOMER_RESPONSE)
    end

    def normalize_source(source)
      source.to_sym == :hook ? ACCOUNT_HOOK : source.to_sym
    rescue NoMethodError
      SYSTEM
    end
  end
end
