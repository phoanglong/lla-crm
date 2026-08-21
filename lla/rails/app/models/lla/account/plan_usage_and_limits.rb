# frozen_string_literal: true

# LLA-owned Captain quota and usage accounting. It extends the base account
# limits instead of copying Chatwoot Cloud plan behavior into the LLA domain.
# rubocop:disable Metrics/ModuleLength
module Lla::Account::PlanUsageAndLimits
  CAPTAIN_RESPONSES = 'captain_responses'
  CAPTAIN_DOCUMENTS = 'captain_documents'
  CAPTAIN_RESPONSES_USAGE = 'captain_responses_usage'
  CAPTAIN_DOCUMENTS_USAGE = 'captain_documents_usage'
  CAPTAIN_RESPONSE_USAGE_VALUE = <<~SQL.squish.freeze
    CASE
      WHEN COALESCE(custom_attributes ->> 'captain_responses_usage', '') ~ '^[0-9]+$'
        THEN (custom_attributes ->> 'captain_responses_usage')::bigint
      ELSE 0
    END
  SQL
  CAPTAIN_RESPONSE_USAGE_LIMIT_CLAUSE = "#{CAPTAIN_RESPONSE_USAGE_VALUE} < ?".freeze
  CAPTAIN_RESPONSE_USAGE_INCREMENT = <<~SQL.squish.freeze
    custom_attributes = jsonb_set(
      COALESCE(custom_attributes, '{}'::jsonb),
      ARRAY['captain_responses_usage']::text[],
      to_jsonb((#{CAPTAIN_RESPONSE_USAGE_VALUE}) + 1),
      true
    )
  SQL
  CAPTAIN_RESPONSE_USAGE_DECREMENT = <<~SQL.squish.freeze
    custom_attributes = jsonb_set(
      COALESCE(custom_attributes, '{}'::jsonb),
      ARRAY['captain_responses_usage']::text[],
      to_jsonb(GREATEST((#{CAPTAIN_RESPONSE_USAGE_VALUE}) - 1, 0)),
      true
    )
  SQL

  LIMIT_SCHEMA = {
    'type' => 'object',
    'properties' => {
      'inboxes' => { 'type' => 'number' },
      'agents' => { 'type' => 'number' },
      'captain_responses' => { 'type' => 'number' },
      'captain_documents' => { 'type' => 'number' },
      'emails' => { 'type' => 'number' }
    },
    'required' => [],
    'additionalProperties' => false
  }.freeze

  # Per-account agent and inbox allowances. The community base answers
  # `ChatwootApp.max_limit` for both, so without this the `limits` column an
  # operator sets in the console — and the `ACCOUNT_AGENTS_LIMIT` /
  # `ACCOUNT_INBOXES_LIMIT` global configs — were read by nothing.
  def usage_limits
    super.merge(
      agents: configured_limit(:agents).to_i,
      inboxes: configured_limit(:inboxes).to_i,
      captain: {
        documents: captain_limit(:documents),
        responses: captain_limit(:responses)
      }
    )
  end

  # Atomically consumes one response unit without exceeding the account limit.
  # Returns false when another worker consumed the last unit first.
  # rubocop:disable Rails/SkipsModelValidations
  def increment_response_usage
    total = captain_monthly_limit[:responses].to_i.clamp(0, ChatwootApp.max_limit)
    return false unless total.positive?

    updated = Account.where(id: id)
                     .where(CAPTAIN_RESPONSE_USAGE_LIMIT_CLAUSE, total)
                     .update_all(CAPTAIN_RESPONSE_USAGE_INCREMENT)
    sync_captain_usage(CAPTAIN_RESPONSES_USAGE) if updated == 1
    updated == 1
  end

  # Releases one previously reserved unit. The guarded SQL transition makes
  # duplicate job failure/retry paths idempotent and never creates a negative
  # counter.
  def decrement_response_usage
    updated = Account.where(id: id)
                     .where("#{CAPTAIN_RESPONSE_USAGE_VALUE} > 0")
                     .update_all(CAPTAIN_RESPONSE_USAGE_DECREMENT)
    sync_captain_usage(CAPTAIN_RESPONSES_USAGE) if updated == 1
    updated == 1
  end

  def reset_response_usage = update_captain_usage(CAPTAIN_RESPONSES_USAGE, 0)

  def update_document_usage = update_captain_usage(CAPTAIN_DOCUMENTS_USAGE, captain_documents.count)
  # rubocop:enable Rails/SkipsModelValidations

  def captain_monthly_limit
    configured_limits = self[:limits].is_a?(Hash) ? self[:limits] : {}
    defaults = default_captain_limits

    {
      documents: non_negative_limit(configured_limits[CAPTAIN_DOCUMENTS] || defaults[:documents]),
      responses: non_negative_limit(configured_limits[CAPTAIN_RESPONSES] || defaults[:responses])
    }.with_indifferent_access
  end

  private

  def captain_limit(type)
    total = captain_monthly_limit[type].to_i
    usage = captain_usage(type)

    {
      total_count: total,
      current_available: (total - usage[:consumed] - usage[:reserved]).clamp(0, total),
      consumed: usage[:consumed]
    }.tap { |result| result[:reserved] = usage[:reserved] if type == :responses }
  end

  def captain_usage(type)
    return current_response_usage if type == :responses

    { consumed: non_negative_limit(custom_attributes[CAPTAIN_DOCUMENTS_USAGE]), reserved: 0 }
  end

  def current_response_usage
    now = Time.current
    ledger = Lla::Captain::QuotaLedger.where(account_id: id, bucket: Lla::Captain::QuotaLedger::BUCKET)
                                      .where('period_start <= ? AND period_end > ?', now, now)
                                      .order(period_start: :desc)
                                      .first
    return { consumed: non_negative_limit(custom_attributes[CAPTAIN_RESPONSES_USAGE]), reserved: 0 } unless ledger

    {
      consumed: non_negative_limit(ledger.opening_consumed_units + ledger.consumed_units),
      reserved: non_negative_limit(ledger.reserved_units)
    }
  end

  def default_captain_limits
    raw = InstallationConfig.find_by(name: 'CAPTAIN_CLOUD_PLAN_LIMITS')&.value
    return unlimited_captain_limits if raw.blank?

    configured_plan_limits(parse_captain_limits(raw))
  rescue JSON::ParserError, TypeError => e
    Rails.logger.warn("LLA Captain quota configuration rejected account_id=#{id} error=#{e.class.name}")
    zero_captain_limits
  end

  def parse_captain_limits(raw) = raw.is_a?(String) ? JSON.parse(raw) : raw

  def configured_plan_limits(parsed)
    return zero_captain_limits unless parsed.is_a?(Hash) && plan_name.present?

    selected = parsed.with_indifferent_access[plan_name.downcase]
    selected.is_a?(Hash) ? selected.with_indifferent_access : zero_captain_limits
  end

  def unlimited_captain_limits
    { documents: ChatwootApp.max_limit, responses: ChatwootApp.max_limit }.with_indifferent_access
  end

  def zero_captain_limits
    { documents: 0, responses: 0 }.with_indifferent_access
  end

  def plan_name = custom_attributes['plan_name'].to_s.presence

  def non_negative_limit(value)
    value.to_i.clamp(0, ChatwootApp.max_limit)
  end

  # Atomic jsonb_set avoids replacing unrelated custom_attributes keys.
  # rubocop:disable Rails/SkipsModelValidations
  def update_captain_usage(key, value)
    safe_value = non_negative_limit(value)
    Account.where(id: id).update_all([
                                       "custom_attributes = jsonb_set(COALESCE(custom_attributes, '{}'::jsonb), " \
                                       'ARRAY[:key]::text[], :value::jsonb, true)',
                                       { key: key, value: safe_value.to_json }
                                     ])
    custom_attributes[key] = safe_value
  end
  # rubocop:enable Rails/SkipsModelValidations

  def sync_captain_usage(key)
    persisted = Account.where(id: id).pick(:custom_attributes) || {}
    custom_attributes[key] = persisted[key]
  end

  # Account row, then global config, then no limit. `limits` is operator-set; the
  # global config is the deployment default.
  def configured_limit(name)
    stored = self[:limits].is_a?(Hash) ? self[:limits][name.to_s] : nil
    return stored if stored.present?

    config_name = "ACCOUNT_#{name.to_s.upcase}_LIMIT"
    configured = GlobalConfig.get(config_name)[config_name]
    return configured if configured.present?

    ChatwootApp.max_limit
  end

  # `limits` is a free-form jsonb column with a `before_validation` hook whose
  # community body is empty, so anything at all could be written into it — including
  # keys nothing reads and values that are not numbers, which then produced a
  # `NoMethodError` deep inside an assignment run rather than a validation error.
  def validate_limit_keys
    unless self[:limits].is_a?(Hash)
      errors.add(:limits, ': Invalid data')
      return
    end

    self[:limits] = {} if self[:limits].blank?
    errors.add(:limits, ': Invalid data') unless JSONSchemer.schema(LIMIT_SCHEMA).valid?(self[:limits])
  end
end
# rubocop:enable Metrics/ModuleLength
