# frozen_string_literal: true

class Lla::Captain::QuotaPolicy
  CUSTOMER_RESPONSE = :customer_response
  INTERNAL = :internal
  SYSTEM = :system
  ACCOUNT_HOOK = :account_hook
  # Tenant gọi bằng khoá của chính nhà cung cấp mà họ khai — tiền trả thẳng cho nhà cung cấp
  # đó, nên không có gì để trừ vào hạn mức của LLA.
  ACCOUNT_PROVIDER = :account_provider

  MATRIX = {
    CUSTOMER_RESPONSE => { SYSTEM => true, ACCOUNT_HOOK => false, ACCOUNT_PROVIDER => false }.freeze,
    INTERNAL => { SYSTEM => false, ACCOUNT_HOOK => false, ACCOUNT_PROVIDER => false }.freeze
  }.freeze

  class << self
    def billable?(workload:, credential_source:)
      workload = workload.to_sym
      source = normalize_source(credential_source)
      return true unless MATRIX.key?(workload)

      MATRIX.fetch(workload).fetch(source, workload == CUSTOMER_RESPONSE)
    end

    def normalize_source(source)
      case source.to_sym
      when :hook then ACCOUNT_HOOK
      when :account then ACCOUNT_PROVIDER
      else source.to_sym
      end
    rescue NoMethodError
      SYSTEM
    end
  end
end
