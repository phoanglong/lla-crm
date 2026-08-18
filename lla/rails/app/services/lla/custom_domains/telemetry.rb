# frozen_string_literal: true

# Structured, redaction-safe operational events for the custom-domain lifecycle.
#
# Only internal identifiers and stable enum-ish codes are ever emitted. Hostnames,
# URLs, ownership tokens, challenge bodies, provider payloads, secrets and customer
# content are not on the allow-list and are dropped rather than truncated, so a new
# call site cannot leak by accident. Every event is emitted exactly once from the
# caller that actually won its compare-and-set, which is what keeps retries from
# double counting.
class Lla::CustomDomains::Telemetry
  NAMESPACE = 'lla.custom_domains'
  # Anything not listed here is dropped. Values must also survive `safe_value`.
  ALLOWED_LABELS = %i[
    account_id portal_id domain_id operation_id predecessor_id
    operation_type provider state previous_state result error_code
    attempts deferrals recovery_attempt duration_ms count
  ].freeze
  SAFE_VALUE = /\A[a-z0-9_.:-]{1,64}\z/
  MAX_INTEGER = 2**53

  def self.emit(event, **labels)
    payload = sanitize(labels).merge(event: safe_value(event))
    return if payload[:event].blank?

    ActiveSupport::Notifications.instrument("#{NAMESPACE}.#{payload[:event]}", payload)
    Rails.logger.info("[LlaCustomDomains] #{payload.map { |key, value| "#{key}=#{value}" }.join(' ')}")
    payload
  end

  # Times a block and emits the duration with the result, without ever touching the
  # block's return value.
  def self.measure(event, **labels)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    emit(event, **labels, duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
    result
  end

  def self.sanitize(labels)
    labels.each_with_object({}) do |(key, value), memo|
      next unless ALLOWED_LABELS.include?(key.to_sym)

      safe = safe_value(value)
      memo[key.to_sym] = safe if safe.present?
    end
  end
  private_class_method :sanitize

  def self.safe_value(value)
    case value
    when Integer then value.abs < MAX_INTEGER ? value : nil
    when Symbol, String then SAFE_VALUE.match?(value.to_s) ? value.to_s : nil
    end
  end
  private_class_method :safe_value
end
